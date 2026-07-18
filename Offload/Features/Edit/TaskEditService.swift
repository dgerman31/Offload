import Foundation
import GRDB

/// Persists task edits and logs each changed field to the `corrections` table (spec §6) —
/// the raw material for correction-driven learning (the model adapting to the user's
/// categories/phrasing over time).
enum TaskEditService {

    /// Pure diff: a Correction row per changed field. Testable without a database.
    static func corrections(from original: TaskItem, to edited: TaskItem) -> [Correction] {
        var rows: [Correction] = []
        func note(_ field: String, _ old: String?, _ new: String?) {
            if (old ?? "") != (new ?? "") {
                rows.append(Correction(taskId: original.id, field: field, modelValue: old, userValue: new))
            }
        }
        note("title", original.title, edited.title)
        note("category", original.category, edited.category)
        note("priority", original.priority, edited.priority)
        note("dueDate", original.dueDate, edited.dueDate)
        return rows
    }

    @MainActor
    static func save(_ edited: TaskItem, original: TaskItem, db: AppDatabase = .shared) async {
        let toSave = edited
        let logged = corrections(from: original, to: edited)
        try? await db.dbQueue.write { database in
            try toSave.update(database)
            for correction in logged { try correction.insert(database) }
        }
    }
}
