import Testing
@testable import Offload

struct EnergyBatchTests {

    @Test("Fills the time budget, priority first, and never exceeds it")
    func fits() {
        let tasks = [
            TaskItem(title: "High 20", priority: "high", effortMinutes: 20),
            TaskItem(title: "High 10", priority: "high", effortMinutes: 10),
            TaskItem(title: "Med 15", priority: "medium", effortMinutes: 15),
            TaskItem(title: "Low 5", priority: "low", effortMinutes: 5)
        ]
        // 30 minutes: high-10 then high-20 = 30 exactly.
        let batch = EnergyBatch.plan(tasks: tasks, minutes: 30)
        #expect(batch.map(\.title) == ["High 10", "High 20"])
        let total = batch.reduce(0) { $0 + ($1.effortMinutes ?? 0) }
        #expect(total <= 30)
    }

    @Test("Unknown effort assumes the default; completed excluded")
    func defaultsAndCompleted() {
        let tasks = [
            TaskItem(title: "No estimate", priority: "high"),            // assumes 15
            TaskItem(title: "Done", priority: "high", status: "completed")
        ]
        #expect(EnergyBatch.plan(tasks: tasks, minutes: 15).map(\.title) == ["No estimate"])
        #expect(EnergyBatch.plan(tasks: tasks, minutes: 10).isEmpty)     // 15 > 10, nothing fits
    }

    @Test("Nothing fits returns empty, not a crash")
    func nothingFits() {
        let tasks = [TaskItem(title: "Big", priority: "high", effortMinutes: 90)]
        #expect(EnergyBatch.plan(tasks: tasks, minutes: 30).isEmpty)
    }
}
