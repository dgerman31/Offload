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

    /// The Sunday on or before a date, so weeks always run Sun–Sat regardless of locale.
    static func startOfWeek(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)   // 1 = Sunday
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: start) ?? start
    }

    static func dateKey(_ date: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    static func datesInScope(_ scope: GymPlanScope, now: Date, calendar: Calendar = .current) -> [Date] {
        switch scope {
        case let .day(date):
            return [calendar.startOfDay(for: date)]
        case let .week(weekStart):
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: weekStart)) }
        }
    }
}

enum GymPlanError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Couldn't reach Gemini to plan this. Check your API key and connection in Settings — there's no offline gym planner."
    }
}
