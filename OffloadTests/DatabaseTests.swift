import Testing
import GRDB
@testable import Offload

/// Exercises the §6 schema: every record type round-trips through SQLite, and the
/// task hierarchy (parent/subtask) persists correctly.
struct DatabaseTests {

    @Test("Migrations create the schema and a task round-trips")
    func taskRoundTrip() throws {
        let appDB = try AppDatabase.makeInMemory()

        let task = TaskItem(title: "Water the plants", category: "Home", priority: "low")
        try appDB.dbQueue.write { db in try task.insert(db) }

        let fetched = try appDB.dbQueue.read { db in
            try TaskItem.fetchOne(db, key: task.id)
        }
        #expect(fetched?.title == "Water the plants")
        #expect(fetched?.category == "Home")
        #expect(fetched?.priority == "low")
        #expect(fetched?.status == "open")
        #expect(fetched?.deleted == false)
    }

    @Test("Parent task and subtasks persist the hierarchy")
    func hierarchy() throws {
        let appDB = try AppDatabase.makeInMemory()

        let parent = TaskItem(title: "Go home")
        let child = TaskItem(title: "Grab charger", parentTaskId: parent.id)
        try appDB.dbQueue.write { db in
            try parent.insert(db)
            try child.insert(db)
        }

        let children = try appDB.dbQueue.read { db in
            try TaskItem.filter(Column("parent_task_id") == parent.id).fetchAll(db)
        }
        #expect(children.count == 1)
        #expect(children.first?.title == "Grab charger")
    }

    @Test("All record types insert without error")
    func allRecordTypes() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbQueue.write { db in
            try Project(title: "Trip planning").insert(db)
            try Capture(rawInput: "remember to call mom", inputType: "voice").insert(db)
            try Correction(field: "category", modelValue: "Work", userValue: "Personal").insert(db)
            try Pattern(patternType: "recurrence", title: "Weekly review").insert(db)
        }
        let counts = try appDB.dbQueue.read { db in
            (try Project.fetchCount(db),
             try Capture.fetchCount(db),
             try Correction.fetchCount(db),
             try Pattern.fetchCount(db))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
        #expect(counts.2 == 1)
        #expect(counts.3 == 1)
    }
}
