import Testing
import Foundation
@testable import Offload

/// Tests the deterministic mapping from model output to domain records. No model calls,
/// so this runs anywhere (the actual on-device inference is exercised on device).
struct CaptureMapperTests {

    @Test("Off-list category falls back to Other; valid category kept")
    func categoryNormalization() {
        #expect(CaptureMapper.normalizedCategory("Work") == "Work")
        #expect(CaptureMapper.normalizedCategory("Groceries") == "Other")
        #expect(CaptureMapper.normalizedCategory("") == "Other")
    }

    @Test("Off-list priority falls back to medium")
    func priorityNormalization() {
        #expect(CaptureMapper.normalizedPriority("high") == "high")
        #expect(CaptureMapper.normalizedPriority("urgent") == "medium")
    }

    @Test("Tags encode to lowercased JSON; empties dropped; nil when none")
    func tagEncoding() {
        #expect(CaptureMapper.encodeTags(["Home", " Store ", ""]) == "[\"home\",\"store\"]")
        #expect(CaptureMapper.encodeTags([]) == nil)
        #expect(CaptureMapper.encodeTags(["  "]) == nil)
    }

    @Test("Tags outside the allowed vocabulary are dropped; duplicates collapse")
    func tagFiltering() {
        #expect(CaptureMapper.encodeTags(["phone", "banana"]) == "[\"phone\"]")
        #expect(CaptureMapper.encodeTags(["gym", "GYM", "gym"]) == "[\"gym\"]")
        #expect(CaptureMapper.encodeTags(["unicorn", "wizardry"]) == nil)
    }

    @Test("A single task never becomes a project, even if the model suggests one")
    func singleTaskNoProject() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy milk", category: "Personal", priority: "medium",
                                  contextTags: ["store"], dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])],
            suggestedProject: "Groceries"   // model over-eagerly suggested a project
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.project == nil)
        #expect(result.tasks.first?.projectId == nil)
    }

    @Test("map() builds a project and links tasks to it")
    func mapWithProject() {
        let extracted = ExtractedCapture(
            summary: "Prep for the trip",
            tasks: [
                ExtractedTask(title: "Book flights", category: "Projects", priority: "high",
                              contextTags: ["computer"], dueDate: nil, recurrenceRule: nil, effortMinutes: 30, subtasks: []),
                ExtractedTask(title: "Pack bags", category: "NotACategory", priority: "meh",
                              contextTags: [], dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])
            ],
            suggestedProject: "Trip planning"
        )

        let result = CaptureMapper.map(extracted)

        #expect(result.project?.title == "Trip planning")
        #expect(result.tasks.count == 2)
        // Both tasks linked to the project.
        #expect(result.tasks.allSatisfy { $0.projectId == result.project?.id })
        // Off-list category/priority normalized.
        #expect(result.tasks[1].category == "Other")
        #expect(result.tasks[1].priority == "medium")
        // Valid values preserved.
        #expect(result.tasks[0].category == "Projects")
        #expect(result.tasks[0].priority == "high")
        #expect(result.tasks[0].effortMinutes == 30)
    }

    @Test("map() normalizes a timezone-less dueDate instead of dropping it (timing bug regression)")
    func mapNormalizesDueDate() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Pay rent", category: "Finance", priority: "high",
                                  contextTags: [], dueDate: "2026-07-19T09:00", recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: [])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        let dueDate = result.tasks.first?.dueDate
        #expect(dueDate != nil)
        // Must be strictly parseable so every downstream reader (old and new) can use it.
        #expect(dueDate.flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
        #expect(result.tasks.first?.dueDateConfidence == 0.5)
    }

    // MARK: Subtask restraint (punch list #4)

    @Test("A single sub-step is dropped — the task stands alone (no trivial decomposition)")
    func loneSubtaskDropped() {
        #expect(CaptureMapper.restrainedSubtasks(parentTitle: "Buy milk", subtasks: ["Go to the store"]) == [])
    }

    @Test("A subtask that restates the parent errand is dropped")
    func restatingSubtaskDropped() {
        // Parent already says it; the subtask just repeats it → not a distinct step.
        #expect(CaptureMapper.restrainedSubtasks(parentTitle: "Go to the store to buy milk",
                                                 subtasks: ["Buy milk", "Go to the store"]) == [])
        #expect(CaptureMapper.restrainedSubtasks(parentTitle: "Buy milk",
                                                 subtasks: ["Buy milk!", "buy MILK"]) == [])
    }

    @Test("Two or more genuinely distinct sub-steps are kept")
    func distinctSubtasksKept() {
        let kept = CaptureMapper.restrainedSubtasks(parentTitle: "Go home",
                                                    subtasks: ["Grab charger", "Water plants", "Grab charger"])
        #expect(kept == ["Grab charger", "Water plants"])   // duplicate collapsed
    }

    @Test("map() drops trivial single-subtask decomposition end to end")
    func mapDropsTrivialSubtasks() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy milk", category: "Personal", priority: "medium",
                                  contextTags: ["store"], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: ["Go to the store to buy milk"])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.tasks.count == 1)   // just the parent; no child
    }

    // MARK: Appointment classification (punch list #6)

    @Test("An appointment with a due date is tracked for calendar-event creation")
    func appointmentTracked() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Dentist", category: "Health", priority: "medium",
                                  contextTags: [], dueDate: "2026-07-21T15:00:00Z", recurrenceRule: nil,
                                  effortMinutes: 60, isAppointment: true, subtasks: [])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.appointmentTaskIds.count == 1)
        #expect(result.appointmentTaskIds.contains(result.tasks[0].id))
    }

    @Test("An appointment with NO due date is not tracked (nothing to schedule)")
    func appointmentWithoutDueDateIgnored() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Dentist sometime", category: "Health", priority: "medium",
                                  contextTags: [], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: nil, isAppointment: true, subtasks: [])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.appointmentTaskIds.isEmpty)
    }

    @Test("A plain to-do is never tracked as an appointment")
    func todoNotAppointment() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy milk", category: "Personal", priority: "medium",
                                  contextTags: [], dueDate: "2026-07-21T15:00:00Z", recurrenceRule: nil,
                                  effortMinutes: nil, isAppointment: false, subtasks: [])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.appointmentTaskIds.isEmpty)
    }

    @Test("map() with no suggested project leaves tasks unlinked")
    func mapWithoutProject() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Call mom", category: "Personal", priority: "medium",
                                  contextTags: ["phone"], dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.project == nil)
        #expect(result.tasks.first?.projectId == nil)
        #expect(result.tasks.first?.contextTags == "[\"phone\"]")
    }
}
