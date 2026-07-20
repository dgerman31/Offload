import Foundation
import GRDB

/// Observes one project: its direct subfolders (with their own rollups) and its tasks split
/// into To-do / Done (spec §5.4 project detail).
@MainActor
@Observable
final class ProjectDetailStore {
    private(set) var todo: [TaskItem] = []
    private(set) var done: [TaskItem] = []
    private(set) var subfolders: [ProjectStore.Summary] = []

    private let projectId: String
    private let db: AppDatabase

    init(projectId: String, db: AppDatabase = .shared) {
        self.projectId = projectId
        self.db = db
    }

    func observe() async {
        let pid = projectId   // capture a Sendable value, not self
        let observation = ValueObservation.tracking { db -> ([TaskItem], [ProjectStore.Summary]) in
            let tasks = try TaskItem
                .filter(Column("deleted") == false)
                .filter(Column("project_id") == pid)
                .order(Column("created_at"))
                .fetchAll(db)
            // Reuse the shared tree builder, then take just this project's direct children.
            let tree = try ProjectStore.fetchTree(db)
            let children = ProjectDetailStore.findChildren(of: pid, in: tree.roots)
            return (tasks, children)
        }
        do {
            for try await (tasks, children) in observation.values(in: db.dbQueue) {
                todo = tasks.filter { $0.status != "completed" }
                done = tasks.filter { $0.status == "completed" }
                subfolders = children
            }
        } catch {
            // Observation ended.
        }
    }

    /// Depth-first search for a project's node in the tree, returning its direct children.
    nonisolated static func findChildren(of id: String, in summaries: [ProjectStore.Summary]) -> [ProjectStore.Summary] {
        for summary in summaries {
            if summary.id == id { return summary.children }
            let nested = findChildren(of: id, in: summary.children)
            if !nested.isEmpty { return nested }
        }
        return []
    }

    func addSubfolder(named title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let child = Project(title: trimmed, parentProjectId: projectId)
        try? await db.dbQueue.write { try child.insert($0) }
        Haptics.success()
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
