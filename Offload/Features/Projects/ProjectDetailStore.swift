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
                // Manual order wins when set (drag-to-reorder); un-reordered tasks keep capture
                // order. Sorting in Swift keeps this independent of any GRDB ordering nuance.
                todo = ProjectDetailStore.byManualOrder(tasks.filter { $0.status != "completed" })
                done = tasks.filter { $0.status == "completed" }
                subfolders = children
            }
        } catch {
            // Observation ended.
        }
    }

    /// Reorder a list the way SwiftUI's `.onMove` intends, without depending on SwiftUI in a
    /// store: `destination` is an offset in the pre-removal list. Pure, so it's unit-testable.
    nonisolated static func moved(_ items: [TaskItem], fromOffsets source: IndexSet, toOffset destination: Int) -> [TaskItem] {
        var result = items
        let moving = source.sorted().map { result[$0] }
        for index in source.sorted(by: >) { result.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: min(max(insertAt, 0), result.count))
        return result
    }

    /// Manual sort_order first (lower = higher), then capture order for anything never dragged.
    nonisolated static func byManualOrder(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            let lo = lhs.sortOrder ?? .greatestFiniteMagnitude
            let ro = rhs.sortOrder ?? .greatestFiniteMagnitude
            if lo != ro { return lo < ro }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Drag-to-reorder: apply the move locally for an instant response, then persist a compact
    /// 0..<n ordering for the whole to-do list so it survives relaunch and future captures slot
    /// below it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        let reordered = ProjectDetailStore.moved(todo, fromOffsets: source, toOffset: destination)
        todo = reordered
        let updates = reordered.enumerated().map { index, task -> TaskItem in
            var t = task
            t.sortOrder = Double(index)
            return t
        }
        try? await db.dbQueue.write { database in
            for task in updates { try task.update(database) }
        }
        Haptics.light()
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
        await TaskActions.toggleComplete(item, db: db)
    }
}
