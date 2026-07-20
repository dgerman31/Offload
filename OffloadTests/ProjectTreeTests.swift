import Testing
import Foundation
import GRDB
@testable import Offload

/// Covers the project folder tree: nesting, rolled-up progress, and the guards that keep a
/// corrupt parent link from losing projects or hanging the UI.
struct ProjectTreeTests {

    private func totals(_ pairs: [(String, Int, Int)]) -> [String: (total: Int, completed: Int)] {
        var map: [String: (total: Int, completed: Int)] = [:]
        for (id, total, completed) in pairs { map[id] = (total, completed) }
        return map
    }

    @Test("Subfolders nest under their parent and progress rolls up")
    func rollup() {
        let parent = Project(id: "p", title: "Future App Ideas")
        let child = Project(id: "c", title: "Calendar", parentProjectId: "p")

        let tree = ProjectStore.buildTree(
            projects: [parent, child],
            ownTotals: totals([("p", 2, 1), ("c", 4, 3)])
        )

        #expect(tree.count == 1)                    // only the parent is top-level
        let root = tree[0]
        #expect(root.project.id == "p")
        #expect(root.children.count == 1)
        #expect(root.ownTotal == 2)                 // its own tasks
        #expect(root.total == 6)                    // plus the subfolder's
        #expect(root.completed == 4)
        #expect(root.children[0].total == 4)
    }

    @Test("Roll-up reaches through multiple levels of nesting")
    func deepRollup() {
        let a = Project(id: "a", title: "A")
        let b = Project(id: "b", title: "B", parentProjectId: "a")
        let c = Project(id: "c", title: "C", parentProjectId: "b")

        let tree = ProjectStore.buildTree(
            projects: [a, b, c],
            ownTotals: totals([("a", 1, 0), ("b", 1, 1), ("c", 2, 2)])
        )
        #expect(tree.count == 1)
        #expect(tree[0].total == 4)
        #expect(tree[0].completed == 3)
    }

    @Test("A project whose parent is gone is promoted, not lost")
    func orphanPromoted() {
        let orphan = Project(id: "o", title: "Orphan", parentProjectId: "missing")
        let tree = ProjectStore.buildTree(projects: [orphan], ownTotals: totals([("o", 1, 0)]))
        #expect(tree.count == 1)
        #expect(tree[0].project.id == "o")
    }

    @Test("A project can't be its own parent")
    func selfParentIgnored() {
        let loop = Project(id: "x", title: "Loop", parentProjectId: "x")
        let tree = ProjectStore.buildTree(projects: [loop], ownTotals: totals([("x", 0, 0)]))
        #expect(tree.count == 1)
        #expect(tree[0].children.isEmpty)
    }

    @Test("Empty projects report zero progress rather than dividing by zero")
    func emptyProject() {
        let empty = Project(id: "e", title: "Empty")
        let tree = ProjectStore.buildTree(projects: [empty], ownTotals: [:])
        #expect(tree[0].total == 0)
        #expect(tree[0].progress == 0)
    }

    // MARK: Persistence

    @Test("A subfolder round-trips through SQLite with its parent link")
    func subfolderPersists() async throws {
        let db = try AppDatabase.makeInMemory()
        let parent = Project(title: "Future App Ideas")
        let child = Project(title: "Calendar work", parentProjectId: parent.id)
        try await db.dbQueue.write { db in
            try parent.insert(db)
            try child.insert(db)
        }

        let fetched = try await db.dbQueue.read { try Project.fetchOne($0, key: child.id) }
        #expect(fetched?.parentProjectId == parent.id)

        let tree = try await db.dbQueue.read { try ProjectStore.fetchTree($0) }
        #expect(tree.roots.count == 1)
        #expect(tree.roots[0].children.count == 1)
        #expect(tree.all.count == 2)
    }

    @Test("Descendant lookup collects the whole branch")
    func descendants() async throws {
        let db = try AppDatabase.makeInMemory()
        let a = Project(title: "A")
        let b = Project(title: "B", parentProjectId: a.id)
        let c = Project(title: "C", parentProjectId: b.id)
        let unrelated = Project(title: "Z")
        try await db.dbQueue.write { db in
            try a.insert(db); try b.insert(db); try c.insert(db); try unrelated.insert(db)
        }

        let ids = try await db.dbQueue.read { try ProjectStore.descendantIds(of: a.id, in: $0) }
        #expect(Set(ids) == Set([a.id, b.id, c.id]))
        #expect(!ids.contains(unrelated.id))
    }
}
