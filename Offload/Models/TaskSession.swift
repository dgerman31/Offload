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
    /// Whether this sitting is the one that finished the task, as opposed to another block of a
    /// job still in progress. Kept as history rather than used by `drift`, which reads completion
    /// from the task itself — the task is the thing that knows whether it's done.
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

    /// Every sitting logged against one task, newest first.
    static func sessions(taskId: String, db: AppDatabase = .shared) async -> [TaskSession] {
        (try? await db.dbQueue.read { database in
            try TaskSession
                .filter(Column("task_id") == taskId)
                .order(Column("started_at").desc)
                .fetchAll(database)
        }) ?? []
    }

    /// Every session on record, newest first.
    static func all(db: AppDatabase = .shared) async -> [TaskSession] {
        (try? await db.dbQueue.read { database in
            try TaskSession.order(Column("started_at").desc).fetchAll(database)
        }) ?? []
    }

    /// Every focused minute ever logged against one task, across every sitting.
    ///
    /// This is the number that makes long work legible: "enter the REDCap data" is a four-hour job
    /// spread over nine sittings and five days, and the only honest question about it is how much
    /// of that four hours you've actually spent.
    nonisolated static func spentMinutes(_ sessions: [TaskSession], taskId: String) -> Int {
        sessions.filter { $0.taskId == taskId }.reduce(0) { $0 + $1.actualMinutes }
    }

    /// How this person's real time compares to their estimates, as a multiplier: 1.4 means work
    /// reliably takes about 40% longer than predicted. `nil` until there's enough history to mean
    /// anything.
    ///
    /// **One data point per finished task, not per sitting.** The obvious version — comparing each
    /// session's actual minutes to what the timer was set to — measures nothing, because the timer
    /// was set to 25 minutes and it ran for 25 minutes. It would report that every estimate is
    /// perfect while a four-hour job quietly took nine. The estimate being tested is the *task's*
    /// (`effortMinutes`), and it isn't answerable until the task is done, however many days that
    /// takes. So a task contributes exactly once: everything logged against it, over what it was
    /// estimated at.
    ///
    /// The **median** rather than the mean. One timer left running through lunch produces a ratio
    /// of 6, and a mean would let that single afternoon rewrite every estimate the planner makes.
    ///
    /// Known undercount: work done without starting the timer is invisible here, so a task worked
    /// on off-app reads as faster than it was. Nothing in the data can distinguish that from a task
    /// that genuinely went quickly, which is another reason to treat the figure as a suggestion
    /// rather than a correction.
    ///
    /// Pure, so the rule is testable without a database.
    nonisolated static func drift(
        sessions: [TaskSession],
        tasks: [TaskItem],
        category: String? = nil,
        minimumSample: Int = minimumSample
    ) -> Double? {
        let all = ratios(sessions: sessions, tasks: tasks)
        guard let category else { return median(all.map(\.ratio), minimumSample: minimumSample) }
        // A category with its own history uses it; one without inherits the overall figure. Work
        // and Personal drift differently, and a single global number averages a rotation into the
        // same shape as an errand.
        let matching = all.filter { $0.category == category }.map(\.ratio)
        return median(matching, minimumSample: minimumSample)
            ?? median(all.map(\.ratio), minimumSample: minimumSample)
    }

    /// One finished task's verdict: everything logged against it, over what it was estimated at.
    private nonisolated static func ratios(
        sessions: [TaskSession],
        tasks: [TaskItem]
    ) -> [(category: String?, ratio: Double)] {
        let byTask = Dictionary(grouping: sessions, by: \.taskId)
        return tasks.compactMap { task in
            // Measured against the estimate *before* any learned correction, deliberately. If drift
            // were measured against its own output it would converge to 1, stop correcting, drift
            // back out, and correct again — a slow oscillation. Anchoring it to the raw estimate
            // keeps it a stable fact about how wrong first guesses are, which is the thing being
            // corrected for.
            let raw = LearnedEstimate.decode(task.metadata)?.original ?? task.effortMinutes
            guard task.status == "completed", !task.deleted,
                  let estimate = raw, estimate > 0,
                  let logged = byTask[task.id] else { return nil }
            let spent = logged.reduce(0) { $0 + $1.actualMinutes }
            guard spent > 0 else { return nil }
            return (task.category, Double(spent) / Double(estimate))
        }
    }

    private nonisolated static func median(_ values: [Double], minimumSample: Int) -> Double? {
        let sorted = values.sorted()
        guard sorted.count >= minimumSample else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
