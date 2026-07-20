import Foundation
import GRDB

/// Observes tasks reactively (GRDB `ValueObservation` as an async sequence) and publishes
/// them for SwiftUI. Because organization happens at capture time, the Home tab just
/// reflects the already-sorted world (spec §5.1).
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
    /// dashboard needs them to count today's progress.
    private(set) var allTasks: [TaskItem] = []

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

    /// Stream non-deleted tasks, newest first. Drive from a SwiftUI `.task {}` so it's
    /// cancelled with the view.
    func observe() async {
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
            // Observation ended (e.g. cancelled). Nothing to surface.
        }
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

    /// Reverse the last undoable action by writing its prior state back.
    func performUndo() async {
        guard let restore = undo?.restore else { return }
        undo = nil
        try? await db.dbQueue.write { try restore.update($0) }
    }

    func clearUndo() { undo = nil }
}
