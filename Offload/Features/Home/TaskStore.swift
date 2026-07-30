import Foundation
import GRDB

/// A single, app-wide live stream of the `tasks` table. Before the app switched to a real native
/// tab bar (which keeps every tab's view — and its `@State private var store = TaskStore()` —
/// alive simultaneously), each screen's own `ValueObservation` was mostly harmless since only one
/// was ever actually running. Now Home, Day, and anything else that observes tasks all stay
/// mounted at once, so without this every task edit was triggering a full-table refetch on each
/// of them in parallel. `TaskStore.allTasks` delegates here so no call site has to change.
///
/// The claim that this made the problem go away was only true of `TaskStore` itself: `StatsStore`
/// kept its own full-table observation running in the permanently-mounted Settings tab until it
/// was moved over too. Anything new that needs the whole task table belongs here as well — a
/// second `ValueObservation.tracking` on `tasks` re-earns the original cost in full.
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

    /// Silently roll a task still sitting in a past day forward to today — the automatic half of
    /// `OverdueSweeper`'s rule that nothing stays overdue.
    ///
    /// A task that had a **real time keeps it**, along with its pin. This used to flatten
    /// everything to an unpinned whole-day intention, which threw away the one piece of
    /// information the user had actually supplied: a 6am ritual came back as an undated "Anytime"
    /// item, which is the same landing-in-Anytime complaint that got auto-fit rewritten. Undated
    /// and whole-day work still rolls forward as whole-day, because there's no time to keep.
    ///
    /// If that hour has already passed today, the task takes the next quarter-hour instead.
    /// Preserving 6am at 9am would leave it overdue the moment it moved — rolling forever and
    /// never becoming actionable.
    func rollToToday(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) async {
        let placement = OverdueSweeper.rolledPlacement(for: task, now: now, calendar: calendar)
        var updated = task
        updated.dueDate = DueDate.canonicalString(from: placement.dueDate)
        updated.dueIsAllDay = placement.isAllDay
        // A kept pin is left exactly as it was — it says "I chose this hour", which is still true.
        if !placement.keepsPin { updated.pinned = false }
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
    ///
    /// All of it in one transaction. A row per `write` block meant a reflow of 30 tasks cost 30
    /// fsyncs *and* 30 `ValueObservation` fire cycles, each one re-rendering every mounted screen
    /// that reads tasks. Batching doesn't weaken the "touch only what moved" rule — the same rows
    /// are written, just together.
    func commitReflow(_ placed: [LiquidTimeline.Placed]) async {
        let moved: [TaskItem] = placed.filter(\.hasMoved).map { p in
            var updated = p.task
            updated.dueDate = DueDate.canonicalString(from: p.start)
            updated.dueIsAllDay = false
            updated.pinned = false
            return updated
        }
        await writeAll(moved, describing: "reflow")
        Haptics.success()
        undo = nil
        await NotificationSync.shared.refresh()
    }

    /// Persist a task dragged to a specific time on the Day tab's grid.
    ///
    /// One row, no re-plan: the user pointed at a time, so that task goes there and nothing else
    /// on the day is touched. That's the whole difference from `applyReorder` below, which
    /// re-derives every time on the day from a new *order* — right for a list, wrong for a grid,
    /// where it meant blocks nobody dragged jumped around after each drop.
    ///
    /// The new time pins. A time chosen by hand is a commitment everywhere else in the app
    /// (`AddTaskSheet` says so in as many words), and leaving a dragged block soft would let the
    /// next "Plan my day" quietly undo the drag. The block stays draggable afterwards — `DayView`
    /// gates dragging on ownership, not on whether something is pinned — so pinning costs nothing.
    func moveTask(_ task: TaskItem, to start: Date) async {
        var updated = task
        updated.dueDate = DueDate.canonicalString(from: start)
        updated.dueIsAllDay = false
        updated.pinned = true
        updated.dueDateConfidence = 1.0
        await writeAll([updated], describing: "move")
        Haptics.light()
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
    ///
    /// One transaction for the whole reorder, for the reason `commitReflow` documents: a 30-task
    /// drag used to be 30 separate writes, and so 30 observation fire cycles — each of which
    /// rebuilds the Day tab's timeline, the very screen the drag happened on.
    func applyReorder(_ orderedIds: [String], on day: Date, events: [CalendarEvent], now: Date = Date(), calendar: Calendar = .current) async {
        let current = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        let plan = DayPlanner.plan(tasks: current, events: events, on: day, now: now,
                                   calendar: calendar,
                                   dayStartHour: DayPlanner.storedDayStartHour(),
                                   dayEndHour: DayPlanner.storedDayEndHour(),
                                   preferredOrder: orderedIds,
                                   protected: ProtectedTime.stored())
        let originalById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var moved: [TaskItem] = []
        for scheduled in plan.scheduled {
            guard let original = originalById[scheduled.task.id] else { continue }
            let originalStart = DueDate.parse(original.dueDate)
            guard originalStart != scheduled.start else { continue }   // only touch what moved
            var updated = original
            updated.dueDate = DueDate.canonicalString(from: scheduled.start)
            updated.dueIsAllDay = false
            updated.pinned = false
            moved.append(updated)
        }
        await writeAll(moved, describing: "reorder")
        Haptics.success()
        await NotificationSync.shared.refresh()
    }

    /// Update every row in a single transaction, or none of them.
    ///
    /// The all-or-nothing part is a real change from the previous per-row `try?`: a mid-batch
    /// failure now rolls the whole batch back instead of leaving a half-applied schedule. That's
    /// the better outcome for a reorder or a reflow, both of which describe one coherent plan —
    /// and unlike the silent per-row version, it says so in the log.
    private func writeAll(_ tasks: [TaskItem], describing operation: String) async {
        guard !tasks.isEmpty else { return }
        do {
            try await db.dbQueue.write { database in
                for task in tasks { try task.update(database) }
            }
        } catch {
            Log.database.error("Batched \(operation, privacy: .public) write of \(tasks.count, privacy: .public) rows failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reverse the last undoable action by writing its prior state back.
    func performUndo() async {
        guard let restore = undo?.restore else { return }
        undo = nil
        try? await db.dbQueue.write { try restore.update($0) }
    }

    func clearUndo() { undo = nil }
}
