import Foundation
import GRDB

/// Observes projects with live progress derived from their tasks (spec §5.4), arranged as a
/// tree so a project can hold subfolders. Progress rolls *up*: a parent's numbers include
/// everything in its descendants, which is what makes nesting useful rather than decorative.
@MainActor
@Observable
final class ProjectStore {

    /// A project plus its task rollup. Sendable so it can cross the observation boundary.
    struct Summary: Identifiable, Sendable, Equatable {
        let project: Project
        /// Tasks directly in this project.
        let ownTotal: Int
        let ownCompleted: Int
        /// Including every descendant subfolder.
        let total: Int
        let completed: Int
        /// Direct subfolders, each already rolled up.
        let children: [Summary]

        var id: String { project.id }
        var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
        var hasChildren: Bool { !children.isEmpty }
    }

    /// Top-level projects only; subfolders hang off their parents.
    private(set) var summaries: [Summary] = []
    /// Flat list of every project, for pickers ("move into…", "assign task to…").
    private(set) var allProjects: [Project] = []

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try ProjectStore.fetchTree(db)
        }
        do {
            for try await result in observation.values(in: db.dbQueue) {
                summaries = result.roots
                allProjects = result.all
            }
        } catch {
            // Observation ended.
        }
    }

    // MARK: Mutations

    /// Create a project, optionally nested inside another.
    func create(title: String, parentId: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let project = Project(title: trimmed, parentProjectId: parentId)
        try? await db.dbQueue.write { try project.insert($0) }
        Haptics.success()
    }

    func rename(_ project: Project, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = project
        updated.title = trimmed
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Soft-delete a project and everything nested inside it. Tasks are freed rather than
    /// destroyed — losing captured work to a folder deletion would break the app's promise.
    func delete(_ project: Project) async {
        let id = project.id
        try? await db.dbQueue.write { db in
            let doomed = try Self.descendantIds(of: id, in: db)
            for pid in doomed {
                try db.execute(sql: "UPDATE projects SET deleted = 1 WHERE id = ?", arguments: [pid])
                try db.execute(sql: "UPDATE tasks SET project_id = NULL WHERE project_id = ?", arguments: [pid])
            }
        }
        Haptics.warning()
    }

    /// Re-parent a project. Refuses moves that would create a cycle (into itself or a
    /// descendant), which would orphan the whole branch from the tree.
    func move(_ project: Project, under newParentId: String?) async {
        let id = project.id
        guard newParentId != id else { return }
        var updated = project
        updated.parentProjectId = newParentId
        let toSave = updated
        try? await db.dbQueue.write { db in
            if let newParentId {
                let descendants = try Self.descendantIds(of: id, in: db)
                guard !descendants.contains(newParentId) else { return }   // would cycle
            }
            try toSave.update(db)
        }
    }

    // MARK: Queries

    struct TreeResult: Sendable, Equatable {
        var roots: [Summary]
        var all: [Project]
    }

    /// Pure query (testable): the whole project forest with rolled-up counts.
    /// `nonisolated` because it runs on the database queue, not the main actor.
    nonisolated static func fetchTree(_ db: Database) throws -> TreeResult {
        let projects = try Project
            .filter(Column("deleted") == false)
            .order(Column("created_at").desc)
            .fetchAll(db)

        var ownTotals: [String: (total: Int, completed: Int)] = [:]
        for project in projects {
            let base = TaskItem
                .filter(Column("project_id") == project.id)
                .filter(Column("deleted") == false)
            let total = try base.fetchCount(db)
            let completed = try base.filter(Column("status") == "completed").fetchCount(db)
            ownTotals[project.id] = (total, completed)
        }

        return TreeResult(roots: buildTree(projects: projects, ownTotals: ownTotals), all: projects)
    }

    /// Pure tree assembly + roll-up, separated from SQL so it's directly unit-testable.
    /// Projects whose parent is missing (deleted) are promoted to top level rather than lost.
    nonisolated static func buildTree(
        projects: [Project],
        ownTotals: [String: (total: Int, completed: Int)]
    ) -> [Summary] {
        let validIds = Set(projects.map(\.id))
        var childrenByParent: [String: [Project]] = [:]
        var roots: [Project] = []

        for project in projects {
            if let parent = project.parentProjectId, validIds.contains(parent), parent != project.id {
                childrenByParent[parent, default: []].append(project)
            } else {
                roots.append(project)
            }
        }

        // Depth-guarded so a corrupt cycle can never hang the UI.
        func summarize(_ project: Project, depth: Int) -> Summary {
            let own = ownTotals[project.id] ?? (0, 0)
            let children = depth >= 8
                ? []
                : (childrenByParent[project.id] ?? []).map { summarize($0, depth: depth + 1) }
            return Summary(
                project: project,
                ownTotal: own.total,
                ownCompleted: own.completed,
                total: own.total + children.reduce(0) { $0 + $1.total },
                completed: own.completed + children.reduce(0) { $0 + $1.completed },
                children: children
            )
        }
        return roots.map { summarize($0, depth: 0) }
    }

    /// A project's id plus every descendant's, for cascading operations.
    nonisolated static func descendantIds(of id: String, in db: Database) throws -> [String] {
        let all = try Project.filter(Column("deleted") == false).fetchAll(db)
        var result = [id]
        var frontier = [id]
        var guardCount = 0
        while !frontier.isEmpty, guardCount < 64 {
            guardCount += 1
            let next = all.filter { p in p.parentProjectId.map { frontier.contains($0) } ?? false }
                .map(\.id)
                .filter { !result.contains($0) }
            result.append(contentsOf: next)
            frontier = next
        }
        return result
    }
}
