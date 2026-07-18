import Testing
import GRDB
@testable import Offload

@MainActor
struct ProjectStoreTests {

    @Test("Summaries roll up task counts and progress per project")
    func summaries() async throws {
        let db = try AppDatabase.makeInMemory()
        let project = Project(title: "Move apartments")
        let t1 = TaskItem(title: "Pack kitchen", status: "completed", projectId: project.id)
        let t2 = TaskItem(title: "Book movers", status: "open", projectId: project.id)
        let unrelated = TaskItem(title: "Buy milk")   // no project

        try await db.dbQueue.write { database in
            try project.insert(database)
            try t1.insert(database)
            try t2.insert(database)
            try unrelated.insert(database)
        }

        let summaries = try await db.dbQueue.read { try ProjectStore.fetchSummaries($0) }
        #expect(summaries.count == 1)
        let s = try #require(summaries.first)
        #expect(s.total == 2)          // unrelated task excluded
        #expect(s.completed == 1)
        #expect(abs(s.progress - 0.5) < 0.0001)
    }

    @Test("A project with no tasks has zero progress, not a divide-by-zero")
    func emptyProject() async throws {
        let db = try AppDatabase.makeInMemory()
        let project = Project(title: "Someday")
        try await db.dbQueue.write { try project.insert($0) }

        let summaries = try await db.dbQueue.read { try ProjectStore.fetchSummaries($0) }
        #expect(summaries.first?.total == 0)
        #expect(summaries.first?.progress == 0)
    }
}
