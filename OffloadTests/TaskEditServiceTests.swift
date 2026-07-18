import Testing
@testable import Offload

struct TaskEditServiceTests {

    @Test("Only changed fields produce corrections")
    func changedFields() {
        let original = TaskItem(title: "Buy milk", category: "Personal", priority: "medium")
        var edited = original
        edited.category = "Health"
        edited.priority = "high"

        let corrections = TaskEditService.corrections(from: original, to: edited)
        let fields = Set(corrections.map(\.field))
        #expect(fields == ["category", "priority"])

        let categoryCorrection = corrections.first { $0.field == "category" }
        #expect(categoryCorrection?.modelValue == "Personal")
        #expect(categoryCorrection?.userValue == "Health")
        #expect(categoryCorrection?.taskId == original.id)
    }

    @Test("No changes => no corrections")
    func noChanges() {
        let original = TaskItem(title: "Same", category: "Work", priority: "low")
        #expect(TaskEditService.corrections(from: original, to: original).isEmpty)
    }

    @Test("Due date add/remove is tracked")
    func dueDateChange() {
        let original = TaskItem(title: "Task")           // no due date
        var edited = original
        edited.dueDate = "2026-07-20T09:00:00Z"
        let corrections = TaskEditService.corrections(from: original, to: edited)
        #expect(corrections.map(\.field) == ["dueDate"])
        #expect(corrections.first?.modelValue == nil)
        #expect(corrections.first?.userValue == "2026-07-20T09:00:00Z")
    }
}
