import Testing
import Foundation
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

    // MARK: Drag-to-reorder (Day tab)

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    @Test("Reordering swaps two flexible tasks' times to match the dragged sequence")
    func applyReorderSwapsTimes() async throws {
        let db = try AppDatabase.makeInMemory()
        let cal = utcCalendar
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 9))!

        // Both undated (flexible); the planner places them in "natural" order first.
        let email = TaskItem(title: "Email boss", effortMinutes: 30)
        let gym = TaskItem(title: "Gym", effortMinutes: 30)
        try await db.dbQueue.write { database in
            try email.insert(database)
            try gym.insert(database)
        }

        let store = TaskStore(db: db)
        // Drag "Gym" above "Email boss".
        await store.applyReorder([gym.id, email.id], on: day, events: [], calendar: cal)

        let reloadedGym = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: gym.id) }
        let reloadedEmail = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: email.id) }
        let gymStart = DueDate.parse(reloadedGym?.dueDate)
        let emailStart = DueDate.parse(reloadedEmail?.dueDate)
        #expect(gymStart != nil && emailStart != nil)
        #expect(gymStart! < emailStart!)   // Gym now comes first
        #expect(reloadedGym?.pinned == false)   // still soft — a re-sequencing, not a commitment
    }

    @Test("A pinned commitment is never touched by a reorder")
    func applyReorderLeavesPinnedAlone() async throws {
        let db = try AppDatabase.makeInMemory()
        let cal = utcCalendar
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 9))!
        let dueISO = ISO8601DateFormatter().string(from: cal.date(from: DateComponents(
            year: 2026, month: 7, day: 22, hour: 15))!)

        let meeting = TaskItem(title: "Meeting", dueDate: dueISO, pinned: true)
        try await db.dbQueue.write { try meeting.insert($0) }

        let store = TaskStore(db: db)
        // A pinned task never appears in the reorder sheet's list, but confirm applyReorder is
        // a no-op for it even if somehow asked to reorder around it.
        await store.applyReorder([meeting.id], on: day, events: [], calendar: cal)

        let reloaded = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: meeting.id) }
        #expect(reloaded?.dueDate == meeting.dueDate)   // untouched
    }
}
