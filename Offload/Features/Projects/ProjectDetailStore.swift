import Foundation
import GRDB

/// Observes one project's tasks, split into To-do / Done (spec §5.4 project detail).
@MainActor
@Observable
final class ProjectDetailStore {
    private(set) var todo: [TaskItem] = []
    private(set) var done: [TaskItem] = []

    private let projectId: String
    private let db: AppDatabase

    init(projectId: String, db: AppDatabase = .shared) {
        self.projectId = projectId
        self.db = db
    }

    func observe() async {
        let pid = projectId   // capture a Sendable value, not self
        let observation = ValueObservation.tracking { db in
            try TaskItem
                .filter(Column("deleted") == false)
                .filter(Column("project_id") == pid)
                .order(Column("created_at"))
                .fetchAll(db)
        }
        do {
            for try await tasks in observation.values(in: db.dbQueue) {
                todo = tasks.filter { $0.status != "completed" }
                done = tasks.filter { $0.status == "completed" }
            }
        } catch {
            // Observation ended.
        }
    }

    func toggleComplete(_ item: TaskItem) async {
        var updated = item
        let nowCompleted = updated.status != "completed"
        updated.status = nowCompleted ? "completed" : "open"
        updated.completedAt = nowCompleted ? ISO8601DateFormatter().string(from: Date()) : nil
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }
}
