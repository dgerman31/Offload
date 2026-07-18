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

    private(set) var openTasks: [TaskItem] = []
    var undo: UndoState?

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    /// Stream open (non-deleted, non-completed) tasks, newest first. Drive from a SwiftUI
    /// `.task {}` so it's cancelled with the view.
    func observe() async {
        let observation = ValueObservation.tracking { db in
            try TaskItem
                .filter(Column("deleted") == false)
                .filter(Column("status") != "completed")
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
        do {
            for try await tasks in observation.values(in: db.dbQueue) {
                openTasks = tasks
            }
        } catch {
            // Observation ended (e.g. cancelled). Nothing to surface.
        }
    }

    /// Toggle completion. Writes an immutable copy (the async @Sendable write can't capture a var).
    func toggleComplete(_ item: TaskItem) async {
        var updated = item
        let nowCompleted = updated.status != "completed"
        updated.status = nowCompleted ? "completed" : "open"
        updated.completedAt = nowCompleted ? ISO8601DateFormatter().string(from: Date()) : nil
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
        // Offer undo when a task leaves the list (completed).
        if nowCompleted {
            undo = UndoState(message: "Completed “\(item.title)”", restore: item)
        }
    }

    /// Soft-delete (sets `deleted = 1`; the observation filters it out).
    func delete(_ item: TaskItem) async {
        var updated = item
        updated.deleted = true
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
        undo = UndoState(message: "Deleted “\(item.title)”", restore: item)
    }

    /// Reverse the last undoable action by writing its prior state back.
    func performUndo() async {
        guard let restore = undo?.restore else { return }
        undo = nil
        try? await db.dbQueue.write { try restore.update($0) }
    }

    func clearUndo() { undo = nil }
}
