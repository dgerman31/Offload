import Testing
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
                                  contextTags: ["store"], dueDate: nil, recurrenceRule: nil, effortMinutes: nil)],
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
                              contextTags: ["computer"], dueDate: nil, recurrenceRule: nil, effortMinutes: 30),
                ExtractedTask(title: "Pack bags", category: "NotACategory", priority: "meh",
                              contextTags: [], dueDate: nil, recurrenceRule: nil, effortMinutes: nil)
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

    @Test("map() with no suggested project leaves tasks unlinked")
    func mapWithoutProject() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Call mom", category: "Personal", priority: "medium",
                                  contextTags: ["phone"], dueDate: nil, recurrenceRule: nil, effortMinutes: nil)],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.project == nil)
        #expect(result.tasks.first?.projectId == nil)
        #expect(result.tasks.first?.contextTags == "[\"phone\"]")
    }
}
