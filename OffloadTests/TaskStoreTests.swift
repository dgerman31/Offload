import Testing
import GRDB
@testable import Offload

@MainActor
struct TaskStoreTests {

    @Test("toggleComplete flips status and stamps completedAt, then back")
    func toggle() async throws {
        let db = try AppDatabase.makeInMemory()
        let task = TaskItem(title: "Call the vet")
        try await db.dbQueue.write { try task.insert($0) }

        let store = TaskStore(db: db)

        await store.toggleComplete(task)
        let completed = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: task.id) }
        #expect(completed?.status == "completed")
        #expect(completed?.completedAt != nil)

        await store.toggleComplete(completed!)
        let reopened = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: task.id) }
        #expect(reopened?.status == "open")
        #expect(reopened?.completedAt == nil)
    }
}
