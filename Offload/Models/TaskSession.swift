import Foundation
import GRDB

/// One stretch of focused work against one task: what it was estimated to take, and how long it
/// actually took.
///
/// The app has always asked the model to estimate effort and has always run real timers against
/// those estimates — and then thrown the comparison away, banking only a running total of minutes
/// in `UserDefaults`. So the planner has spent every day scheduling against guesses it had no way
/// to check, while the evidence to correct them went past it uncounted.
///
/// `category` is denormalized on purpose: the point of this table is a history that outlives the
/// individual tasks in it, and a session whose task was deleted last month should still count
/// toward how long your Work tends to actually take.
struct TaskSession: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var taskId: String
    var category: String?
    var startedAt: String
    var endedAt: String
    /// What the timer was set to — the estimate this session was testing.
    var plannedMinutes: Int
    /// Minutes actually spent focused, whether or not the timer ran out.
    var actualMinutes: Int
    /// Whether the timer reached zero, as opposed to being stopped early. A session cut short
    /// says nothing about how long the work takes, so the learning ignores those.
    var ranToCompletion: Bool

    static let databaseTableName = "task_sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case category
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case plannedMinutes = "planned_minutes"
        case actualMinutes = "actual_minutes"
        case ranToCompletion = "ran_to_completion"
    }

    init(
        id: String = UUID().uuidString,
        taskId: String,
        category: String? = nil,
        startedAt: String,
        endedAt: String,
        plannedMinutes: Int,
        actualMinutes: Int,
        ranToCompletion: Bool
    ) {
        self.id = id
        self.taskId = taskId
        self.category = category
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes
        self.ranToCompletion = ranToCompletion
    }
}

/// Writing and reading focus history.
enum TaskSessionLog {

    /// Below this many completed sessions, any ratio is noise. Two long days in a row would
    /// otherwise be enough to convince the planner that everything takes twice as long.
    static let minimumSample = 5

    /// Persist a finished session. Best-effort and never propagated: a focus session that
    /// completed successfully must not report a failure because bookkeeping didn't save.
    static func record(
        task: TaskItem,
        plannedMinutes: Int,
        actualMinutes: Int,
        startedAt: Date,
        endedAt: Date = Date(),
        ranToCompletion: Bool,
        db: AppDatabase = .shared
    ) async {
        guard actualMinutes > 0, plannedMinutes > 0 else { return }
        let stamp = ISO8601DateFormatter()
        let session = TaskSession(
            taskId: task.id,
            category: task.category,
            startedAt: stamp.string(from: startedAt),
            endedAt: stamp.string(from: endedAt),
            plannedMinutes: plannedMinutes,
            actualMinutes: actualMinutes,
            ranToCompletion: ranToCompletion
        )
        do {
            try await db.dbQueue.write { try session.insert($0) }
        } catch {
            // Shape only — a GRDB error's description carries the failing SQL and its bound
            // arguments, which here would include the task's category.
            Log.database.error("Recording a focus session failed: \(CaptureService.errorKind(error), privacy: .public)")
        }
    }

    /// Fetch a task by id — what the focus timer needs when a session that began hours ago ends,
    /// since a snapshot taken at the start may have been renamed, rescheduled, or deleted since.
    static func task(id: String, db: AppDatabase = .shared) async -> TaskItem? {
        try? await db.dbQueue.read { try TaskItem.fetchOne($0, key: id) }
    }

    /// Every session on record, newest first.
    static func all(db: AppDatabase = .shared) async -> [TaskSession] {
        (try? await db.dbQueue.read { database in
            try TaskSession.order(Column("started_at").desc).fetchAll(database)
        }) ?? []
    }

    /// How this person's real focus time compares to the estimates, as a multiplier: 1.4 means
    /// work reliably takes about 40% longer than predicted. `nil` until there's enough history to
    /// mean anything.
    ///
    /// The **median** rather than the mean, deliberately. One session left running through lunch
    /// produces a ratio of 6, and a mean would let that single afternoon rewrite every estimate
    /// the planner makes. Sessions stopped early are excluded for the same reason in reverse —
    /// abandoning a timer after five minutes is a fact about your afternoon, not about the work.
    ///
    /// Pure, so the rule is testable without a database.
    nonisolated static func drift(_ sessions: [TaskSession], minimumSample: Int = minimumSample) -> Double? {
        let ratios = sessions
            .filter { $0.ranToCompletion && $0.plannedMinutes > 0 && $0.actualMinutes > 0 }
            .map { Double($0.actualMinutes) / Double($0.plannedMinutes) }
            .sorted()
        guard ratios.count >= minimumSample else { return nil }
        let middle = ratios.count / 2
        return ratios.count.isMultiple(of: 2)
            ? (ratios[middle - 1] + ratios[middle]) / 2
            : ratios[middle]
    }

    /// The same ratio for one category, falling back to the overall figure when a category
    /// hasn't got its own history yet. Work and Personal drift differently; a single global
    /// number would average a rotation into the same shape as an errand.
    nonisolated static func drift(
        _ sessions: [TaskSession],
        category: String?,
        minimumSample: Int = minimumSample
    ) -> Double? {
        guard let category else { return drift(sessions, minimumSample: minimumSample) }
        let matching = sessions.filter { $0.category == category }
        return drift(matching, minimumSample: minimumSample)
            ?? drift(sessions, minimumSample: minimumSample)
    }
}
