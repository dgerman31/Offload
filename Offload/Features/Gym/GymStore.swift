import Foundation
import GRDB

/// Observes and persists workout sessions, and owns the one rule that ties the Gym tab to the
/// rest of the app: every session gets a lightweight linked `TaskItem` so its time and title show
/// up on Home/Day, and deleting or regenerating a session cleans up that task too. Nothing else
/// about the app changes — the workout's real content (exercises, sets, muscle groups) lives only
/// here, never duplicated into the task.
@MainActor
@Observable
final class GymStore {
    private(set) var sessions: [WorkoutSession] = []

    private let db: AppDatabase

    init(db: AppDatabase = .shared) {
        self.db = db
    }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try WorkoutSession
                .filter(Column("deleted") == false)
                .order(Column("date"), Column("start_minute"))
                .fetchAll(db)
        }
        do {
            for try await rows in observation.values(in: db.dbQueue) { sessions = rows }
        } catch {
            // Observation ended.
        }
    }

    func sessions(on date: Date, calendar: Calendar = .current) -> [WorkoutSession] {
        let key = Self.dateKey(date)
        return sessions.filter { $0.date == key }
    }

    func sessions(forWeekOf weekStart: Date, calendar: Calendar = .current) -> [WorkoutSession] {
        let days = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart).map(Self.dateKey) })
        return sessions.filter { days.contains($0.date) }
    }

    // MARK: Planning

    /// Ask Gemini to plan a day or week, then save the result — replacing any not-yet-completed
    /// sessions already in that scope (a regenerate), leaving completed history untouched.
    /// Returns the chips to offer, or throws if the cloud isn't available (there's no on-device
    /// fallback for gym planning — surfaced to the UI as an error rather than silently doing
    /// nothing).
    func plan(scope: GymPlanScope, transcript: String, extra: String? = nil, now: Date = Date()) async throws -> [GymChip] {
        let dates = Self.datesInScope(scope, now: now)
        let context = await busyContext(for: dates)
        let existingNow = sessions

        // Routed through AIRouter, same as every other Gemini call — the daily/per-minute budget
        // applies here too, and a stale or missing key surfaces the same way. There's no
        // on-device fallback for gym planning, so `nil` becomes a thrown error for the UI.
        let result = await AIRouter.shared.run(label: "gym-plan") { key in
            try await GymPlannerService(client: GeminiClient(apiKey: key)).plan(
                scope: scope, transcript: transcript, extra: extra,
                busyContext: context, existing: existingNow, now: now
            )
        }
        guard let result else { throw GymPlanError.unavailable }
        try await save(result.sessions, replacingScopeDates: Set(dates.map(Self.dateKey)))
        return result.chips
    }

    private func save(_ newSessions: [WorkoutSession], replacingScopeDates dateKeys: Set<String>) async throws {
        // Regenerate: drop existing non-completed sessions in the replaced days (and their linked
        // tasks) before inserting the fresh plan.
        let toReplace = sessions.filter { dateKeys.contains($0.date) && $0.status != "completed" }
        for old in toReplace { try await deleteInternal(old) }

        for var session in newSessions {
            let task = Self.makeTask(for: session)
            session.taskId = task.id
            // GRDB's async `write` closure is @Sendable, so a captured `var` doesn't type-check —
            // hand it an immutable copy instead (same convention as TaskActions.delete).
            let toInsert = session
            try await db.dbQueue.write { database in
                try toInsert.insert(database)
                try task.insert(database)
            }
        }
    }

    /// Build the schedule-blocking task for a session: title + time only, nothing else the rest
    /// of the app needs to know. A stated start time is pinned (a real commitment, like a class);
    /// otherwise it's a soft all-day placement on that date.
    private static func makeTask(for session: WorkoutSession) -> TaskItem {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let day = DueDate.parse(session.date + "T00:00") ?? Date()
        let hasTime = session.startMinute != nil
        let due: Date = {
            guard let minute = session.startMinute,
                  let d = calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: day))
            else { return calendar.startOfDay(for: day) }
            return d
        }()
        return TaskItem(
            title: session.title,
            category: "Health",
            priority: "medium",
            dueDate: DueDate.canonicalString(from: due),
            effortMinutes: session.durationMinutes,
            dueIsAllDay: !hasTime,
            pinned: hasTime,
            gymSessionId: session.id
        )
    }

    // MARK: Mutation

    func toggleComplete(_ session: WorkoutSession) async {
        var updated = session
        let completing = session.status != "completed"
        updated.status = completing ? "completed" : "planned"
        updated.completedAt = completing ? ISO8601DateFormatter().string(from: Date()) : nil
        // GRDB's async `write` closure is @Sendable, so a captured `var` doesn't type-check —
        // hand it immutable copies instead (same convention as TaskActions.delete).
        let toSave = updated
        let completedAt = updated.completedAt
        try? await db.dbQueue.write { try toSave.update($0) }
        if let taskId = session.taskId {
            try? await db.dbQueue.write { db in
                guard var task = try TaskItem.fetchOne(db, key: taskId) else { return }
                task.status = completing ? "completed" : "open"
                task.completedAt = completedAt
                try task.update(db)
            }
        }
    }

    func delete(_ session: WorkoutSession) async {
        try? await deleteInternal(session)
    }

    /// Skip a session: mark it skipped, remove its now-meaningless schedule block, and cascade
    /// every later still-planned session forward a day — the missed day doesn't leave a gap in
    /// the middle of the program, the whole rest of the week just shifts to absorb it.
    func skip(_ session: WorkoutSession) async {
        var updated = session
        updated.status = "skipped"
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
        if let taskId = session.taskId {
            try? await db.dbQueue.write { db in
                guard var task = try TaskItem.fetchOne(db, key: taskId) else { return }
                task.deleted = true
                try task.update(db)
            }
        }

        // A frozen snapshot: reading the live `sessions` mid-loop, right after writes that
        // change it, would be racing the observation that refreshes it.
        let before = sessions
        for shift in Self.cascadeAfterSkip(session, in: before) {
            guard var later = before.first(where: { $0.id == shift.id }) else { continue }
            later.date = shift.newDate
            let toSaveLater = later
            try? await db.dbQueue.write { try toSaveLater.update($0) }
            guard let laterTaskId = later.taskId else { continue }
            try? await db.dbQueue.write { db in
                guard var task = try TaskItem.fetchOne(db, key: laterTaskId) else { return }
                if let oldDue = DueDate.parse(task.dueDate),
                   let newDue = Calendar.current.date(byAdding: .day, value: 1, to: oldDue) {
                    task.dueDate = DueDate.canonicalString(from: newDue)
                }
                try task.update(db)
            }
        }
        Haptics.success()
    }

    /// Which sessions should shift, and their new dates, when `skipped` is skipped: every other
    /// still-planned session dated after it moves a day later. Pure and testable; the caller
    /// persists the result. Latest-first order is a defensive nicety only — each new date is
    /// computed independently, not chained off a prior shift, so ordering can't affect correctness.
    nonisolated static func cascadeAfterSkip(
        _ skipped: WorkoutSession, in sessions: [WorkoutSession], calendar: Calendar = .current
    ) -> [(id: String, newDate: String)] {
        sessions
            .filter { $0.id != skipped.id && $0.date > skipped.date && $0.status == "planned" }
            .sorted { $0.date > $1.date }
            .compactMap { session in
                guard let due = DueDate.parse(session.date + "T00:00"),
                      let shifted = calendar.date(byAdding: .day, value: 1, to: due) else { return nil }
                return (id: session.id, newDate: Self.dateKey(shifted))
            }
    }

    // MARK: Logging (active workout)

    /// Apply a mutation to one exercise inside a session and persist the whole session — the
    /// exercise list is one JSON blob, so "check off a set" means rewriting the session, not a
    /// single-row DB update.
    func logExercise(_ exerciseId: String, in session: WorkoutSession, mutate: (inout GymExercise) -> Void) async {
        var exercises = session.exerciseList
        guard let index = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        mutate(&exercises[index])
        var updated = session
        updated.setExerciseList(exercises)
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    // MARK: Consistency

    /// Completed vs. planned-or-completed sessions for a week — skipped ones don't count against
    /// you, since a skip already rescheduled the rest of the program forward to absorb it.
    nonisolated static func weekProgress(
        _ sessions: [WorkoutSession], weekStart: Date, calendar: Calendar = .current
    ) -> (completed: Int, total: Int) {
        let days = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart).map(dateKey) })
        let inWeek = sessions.filter { days.contains($0.date) && $0.status != "skipped" }
        return (inWeek.filter { $0.status == "completed" }.count, inWeek.count)
    }

    private func deleteInternal(_ session: WorkoutSession) async throws {
        var updated = session
        updated.deleted = true
        let toSave = updated
        try await db.dbQueue.write { try toSave.update($0) }
        if let taskId = session.taskId {
            try await db.dbQueue.write { db in
                guard var task = try TaskItem.fetchOne(db, key: taskId) else { return }
                task.deleted = true
                try task.update(db)
            }
        }
    }

    // MARK: Busy-time context for the planner

    /// A plain-text summary of what's already on the schedule for the given days — classes,
    /// other tasks — so the planner can route around real commitments instead of guessing.
    /// A direct one-shot read rather than `SharedTasks`: this only runs on an explicit "plan my
    /// day/week" tap (not a live-updating stream), and `SharedTasks.start()` blocks its caller
    /// for as long as it's the first-ever observer — wrong contract for a one-off read.
    private func busyContext(for dates: [Date]) async -> String {
        let tasks = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false)
                .filter(Column("status") != "completed")
                .fetchAll(database)
        }) ?? []

        let df = DateFormatter(); df.dateFormat = "h:mm a"
        var lines: [String] = []
        for date in dates {
            let key = Self.dateKey(date)
            let dayTasks = tasks.filter { task in
                guard let due = DueDate.parse(task.dueDate) else { return false }
                return Self.dateKey(due) == key && task.gymSessionId == nil
            }
            guard !dayTasks.isEmpty else { continue }
            let parts = dayTasks.map { task -> String in
                guard !task.dueIsAllDay, let due = DueDate.parse(task.dueDate) else { return task.title }
                let end = Calendar.current.date(byAdding: .minute, value: task.effortMinutes ?? 60, to: due) ?? due
                return "\(task.title) \(df.string(from: due))–\(df.string(from: end))"
            }
            lines.append("\(key): \(parts.joined(separator: ", "))")
        }
        return lines.isEmpty ? "Nothing else on the schedule these days." : lines.joined(separator: "\n")
    }

    // MARK: Dates

    /// The Sunday on or before a date, so weeks always run Sun–Sat regardless of locale. `nonisolated`
    /// — pure, touches no actor-isolated state, so it's callable synchronously (tests included)
    /// without an actor hop, same as `ProjectDetailStore`'s pure static helpers.
    nonisolated static func startOfWeek(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)   // 1 = Sunday
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: start) ?? start
    }

    nonisolated static func dateKey(_ date: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    /// Every date "plan this" should touch. For a week, this never reaches backward past today —
    /// re-planning Sunday through Wednesday because today happens to be Wednesday would wipe out
    /// days that already happened. `now` genuinely matters here (it didn't before this fix).
    nonisolated static func datesInScope(_ scope: GymPlanScope, now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        switch scope {
        case let .day(date):
            return [calendar.startOfDay(for: date)]
        case let .week(weekStart):
            let start = max(calendar.startOfDay(for: weekStart), today)
            guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: calendar.startOfDay(for: weekStart)),
                  start <= weekEnd else { return [] }
            let days = calendar.dateComponents([.day], from: start, to: weekEnd).day ?? 0
            return (0...days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
    }
}

enum GymPlanError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Couldn't reach Gemini to plan this. Check your API key and connection in Settings — there's no offline gym planner."
    }
}
