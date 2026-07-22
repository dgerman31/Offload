import Foundation
import GRDB

/// A single, app-wide live stream of the `tasks` table. Before the app switched to a real native
/// tab bar (which keeps every tab's view — and its `@State private var store = TaskStore()` —
/// alive simultaneously), each screen's own `ValueObservation` was mostly harmless since only one
/// was ever actually running. Now Home, Day, and anything else that observes tasks all stay
/// mounted at once, so without this every task edit was triggering a full-table refetch on each
/// of them in parallel. `TaskStore.allTasks` delegates here so no call site has to change.
@MainActor
@Observable
final class SharedTasks {
    static let shared = SharedTasks()
    private(set) var allTasks: [TaskItem] = []
    private var started = false

    private init() {}

    /// Idempotent: the first caller starts the one real observation; anyone else calling this
    /// (another screen's `.task { await store.observe() }`) just returns immediately, since
    /// they're all reading the same `allTasks`.
    func start(db: AppDatabase = .shared) async {
        guard !started else { return }
        started = true
        let observation = ValueObservation.tracking { db in
            try TaskItem
                .filter(Column("deleted") == false)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
        do {
            for try await tasks in observation.values(in: db.dbQueue) {
                allTasks = tasks
            }
        } catch {
            // Observation ended.
        }
        started = false
    }
}

/// Per-screen task actions (complete/delete/snooze/undo) plus a screen-scoped calendar-event
/// window — `rangeEvents` genuinely differs per screen (Day pages through arbitrary weeks; Home
/// only ever wants today), so unlike `allTasks` it stays per-instance rather than shared.
@MainActor
@Observable
final class TaskStore {
    /// A recently-applied action the user can undo (spec §5.7). `restore` is the record's
    /// prior state, written back verbatim to reverse the change.
    struct UndoState: Identifiable {
        let id = UUID()
        let message: String
        let restore: TaskItem
    }

    /// Every non-deleted task, newest first — completed ones included, since the Home
    /// dashboard needs them to count today's progress. Delegates to the single shared stream.
    var allTasks: [TaskItem] { SharedTasks.shared.allTasks }

    /// Calendar events across the visible window (the week strip's fortnight plus whichever
    /// day is selected), so switching days doesn't trigger a fetch every tap.
    private(set) var rangeEvents: [CalendarEvent] = []

    /// Just today's, for the day summary.
    var todayEvents: [CalendarEvent] {
        rangeEvents.filter { Calendar.current.isDate($0.start, inSameDayAs: Date()) }
    }

    var undo: UndoState?

    /// Open (non-completed) tasks — what task lists actually render.
    var openTasks: [TaskItem] { allTasks.filter { $0.status != "completed" } }

    private let db: AppDatabase
    private let calendarReader: any CalendarReading

    init(db: AppDatabase = .shared, calendarReader: any CalendarReading = EventKitCalendarReader()) {
        self.db = db
        self.calendarReader = calendarReader
    }

    /// Join the single shared task stream. Safe to call from every screen that observes tasks —
    /// only the first caller actually starts anything.
    func observe() async {
        await SharedTasks.shared.start(db: db)
    }

    /// Load events covering the week strip *and* the selected day in one fetch, so tapping
    /// through days is instant and the strip's density dots are already populated.
    func loadEvents(around day: Date, now: Date = Date(), calendar: Calendar = .current) async {
        guard await calendarReader.requestAccess() else {
            rangeEvents = []
            return
        }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let start = calendar.startOfDay(for: min(weekStart, day))
        let end = calendar.date(byAdding: .day, value: 21, to: start) ?? start
        rangeEvents = await calendarReader.events(from: start, to: end)
    }

    /// Silently roll a flexible task that's still sitting in a past day forward to today — the
    /// automatic half of `OverdueSweeper`'s rule that nothing stays overdue. Stays a soft,
    /// whole-day intention, unpinned, exactly like any other undated capture.
    func rollToToday(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) async {
        var updated = task
        updated.dueDate = DueDate.canonicalString(from: calendar.startOfDay(for: now))
        updated.dueIsAllDay = true
        updated.pinned = false
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Run `OverdueSweeper` once: auto-move every flexible overdue task to today, and return the
    /// hard-committed ones that still need a reschedule-or-delete decision. Reads directly from
    /// the database rather than the cached `allTasks` — this can run at the very start of Home's
    /// lifecycle, before the reactive stream has necessarily delivered its first value yet.
    func sweepOverdue(now: Date = Date(), calendar: Calendar = .current) async -> [TaskItem] {
        let current = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        let (autoMove, needsDecision) = OverdueSweeper.classify(current, now: now, calendar: calendar)
        for task in autoMove {
            await rollToToday(task, now: now, calendar: calendar)
        }
        return needsDecision
    }

    /// Toggle completion. Writes an immutable copy (the async @Sendable write can't capture a var).
    func toggleComplete(_ item: TaskItem) async {
        let nowCompleted = item.status != "completed"
        let follow = await TaskActions.toggleComplete(item, db: db)
        // Offer undo when a task leaves the list (completed), and say so when finishing it
        // scheduled the next occurrence — otherwise a repeating task silently reappearing
        // looks like a bug rather than the feature it is.
        if nowCompleted {
            let message = follow != nil
                ? "Completed “\(item.title)” · next one scheduled"
                : "Completed “\(item.title)”"
            undo = UndoState(message: message, restore: item)
        }
    }

    /// Soft-delete (sets `deleted = 1`; the observation filters it out).
    func delete(_ item: TaskItem) async {
        await TaskActions.delete(item, db: db)
        undo = UndoState(message: "Deleted “\(item.title)”", restore: item)
    }

    /// Push a task out to a later moment, with undo back to where it was.
    func snooze(_ item: TaskItem, _ preset: TaskActions.Snooze) async {
        await TaskActions.snooze(item, preset, db: db)
        Haptics.light()
        undo = UndoState(message: "Snoozed to \(preset.rawValue.lowercased())", restore: item)
    }

    /// open → in progress → done.
    func advanceStatus(_ item: TaskItem) async {
        await TaskActions.advanceStatus(item, db: db)
        Haptics.light()
    }

    /// Bank a healed timeline: write each reflowed task's projected time back so reminders and
    /// the plan follow reality. Only the tasks that actually moved are touched. They stay soft,
    /// so the timeline can keep healing from here.
    func commitReflow(_ placed: [LiquidTimeline.Placed]) async {
        for p in placed where p.hasMoved {
            var updated = p.task
            updated.dueDate = DueDate.canonicalString(from: p.start)
            updated.dueIsAllDay = false
            updated.pinned = false
            let toSave = updated
            try? await db.dbQueue.write { try toSave.update($0) }
        }
        Haptics.success()
        undo = nil
        await NotificationSync.shared.refresh()
    }

    /// Persist a manual reorder of a day's flexible (non-anchored) tasks: re-run the deterministic
    /// planner for that day with the dragged order as `preferredOrder`, then write back only the
    /// tasks whose time actually changed — same "touch only what moved" discipline as
    /// `commitReflow`. Times stay soft/unpinned; this is a re-sequencing, not a new commitment.
    ///
    /// Reads a fresh snapshot directly from the database rather than the cached `allTasks` (which
    /// now delegates to the single shared task stream) — a one-shot mutation like this wants the
    /// current state at the moment it runs, not whatever the last-observed value happened to be.
    func applyReorder(_ orderedIds: [String], on day: Date, events: [CalendarEvent], now: Date = Date(), calendar: Calendar = .current) async {
        let current = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        let plan = DayPlanner.plan(tasks: current, events: events, on: day, now: now,
                                   calendar: calendar, preferredOrder: orderedIds)
        let originalById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for scheduled in plan.scheduled {
            guard let original = originalById[scheduled.task.id] else { continue }
            let originalStart = DueDate.parse(original.dueDate)
            guard originalStart != scheduled.start else { continue }   // only touch what moved
            var updated = original
            updated.dueDate = DueDate.canonicalString(from: scheduled.start)
            updated.dueIsAllDay = false
            updated.pinned = false
            let toSave = updated
            try? await db.dbQueue.write { try toSave.update($0) }
        }
        Haptics.success()
        await NotificationSync.shared.refresh()
    }

    /// Reverse the last undoable action by writing its prior state back.
    func performUndo() async {
        guard let restore = undo?.restore else { return }
        undo = nil
        try? await db.dbQueue.write { try restore.update($0) }
    }

    func clearUndo() { undo = nil }
}
