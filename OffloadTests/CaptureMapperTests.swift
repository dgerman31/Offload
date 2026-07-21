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

    // MARK: Intent titles — meta-fluff never survives into a stored title

    @Test("actionTitle strips a meta prefix and capitalizes the action")
    func actionTitleStripsFluff() {
        #expect(CaptureMapper.actionTitle("remember to pay bills") == "Pay bills")
        #expect(CaptureMapper.actionTitle("Don't forget to call mom") == "Call mom")
        #expect(CaptureMapper.actionTitle("need to book flights") == "Book flights")
        #expect(CaptureMapper.actionTitle("try to fix the sink") == "Fix the sink")
    }

    @Test("actionTitle strips stacked prefixes and leaves clean titles untouched")
    func actionTitleStackedAndClean() {
        #expect(CaptureMapper.actionTitle("remember to try to water plants") == "Water plants")
        #expect(CaptureMapper.actionTitle("Pay rent") == "Pay rent")
        #expect(CaptureMapper.actionTitle("Retrieve jacket from school") == "Retrieve jacket from school")
    }

    @Test("actionTitle never empties a title — fluff-only input survives (capitalized, not stripped)")
    func actionTitleNeverEmpty() {
        // No trailing space, so no prefix matches; only the capitalization pass applies.
        #expect(CaptureMapper.actionTitle("remember to") == "Remember to")
        #expect(CaptureMapper.actionTitle("  ") == "")   // whitespace-only was already empty
    }

    @Test("map() cleans meta-fluff from parent and subtask titles end to end")
    func mapCleansTitles() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "remember to go home", category: "Personal", priority: "medium",
                                  contextTags: [], dueDate: nil, recurrenceRule: nil, effortMinutes: nil,
                                  subtasks: ["need to grab charger", "don't forget to water plants"])],
            suggestedProject: nil)
        let result = CaptureMapper.map(extracted)
        #expect(result.tasks.map(\.title) == ["Go home", "Grab charger", "Water plants"])
    }

    // MARK: Effort — trust the model, clamp only for data integrity

    @Test("Effort clamp keeps sane values, rejects zero/negative, caps the absurd")
    func effortClamp() {
        #expect(CaptureMapper.clampedEffort(30) == 30)
        #expect(CaptureMapper.clampedEffort(nil) == nil)
        #expect(CaptureMapper.clampedEffort(0) == nil)          // not a real estimate
        #expect(CaptureMapper.clampedEffort(-5) == nil)
        #expect(CaptureMapper.clampedEffort(99999) == CaptureMapper.maxEffortMinutes)  // capped
    }

    @Test("The model's effort estimate is trusted even without a stated duration")
    func inferredEffortKept() {
        // New philosophy: Gemini can reasonably infer "review the deck" ≈ 20m — no word-list gate.
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Review deck", category: "Work", priority: "medium",
                                  contextTags: [], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: 20, subtasks: [])],
            suggestedProject: nil)
        let result = CaptureMapper.map(extracted, sourceText: "review the deck")
        #expect(result.tasks.first?.effortMinutes == 20)
    }

    // MARK: Details

    @Test("Model details land on the task; blank details become nil")
    func detailsMapped() {
        let withDetails = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Text landlord", details: "Third leak this year.",
                                  category: "Personal", priority: "medium", contextTags: [],
                                  dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])],
            suggestedProject: nil)
        #expect(CaptureMapper.map(withDetails).tasks.first?.descriptionText == "Third leak this year.")

        let blank = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy milk", details: "   ", category: "Personal",
                                  priority: "medium", contextTags: [], dueDate: nil,
                                  recurrenceRule: nil, effortMinutes: nil, subtasks: [])],
            suggestedProject: nil)
        #expect(CaptureMapper.map(blank).tasks.first?.descriptionText == nil)
    }

    // MARK: Priority guardrail — imminent work is never "low"

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func isoUTC(day: Int, hour: Int = 12) -> String {
        let d = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
    private func dateUTC(day: Int, hour: Int = 9) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    @Test("A low task due today or overdue is lifted to medium")
    func lowLiftedWhenImminent() {
        let now = dateUTC(day: 18)
        #expect(CaptureMapper.resolvedPriority("low", dueDate: isoUTC(day: 18, hour: 17), now: now, calendar: utcCalendar) == "medium") // today
        #expect(CaptureMapper.resolvedPriority("low", dueDate: isoUTC(day: 16), now: now, calendar: utcCalendar) == "medium")           // overdue
    }

    @Test("Guardrail leaves future-dated low, undated low, and high/medium untouched")
    func guardrailRespectsOthers() {
        let now = dateUTC(day: 18)
        #expect(CaptureMapper.resolvedPriority("low", dueDate: isoUTC(day: 25), now: now, calendar: utcCalendar) == "low")   // future
        #expect(CaptureMapper.resolvedPriority("low", dueDate: nil, now: now, calendar: utcCalendar) == "low")               // undated
        #expect(CaptureMapper.resolvedPriority("high", dueDate: isoUTC(day: 18), now: now, calendar: utcCalendar) == "high")
        #expect(CaptureMapper.resolvedPriority("medium", dueDate: isoUTC(day: 16), now: now, calendar: utcCalendar) == "medium")
    }

    @Test("map() applies the priority guardrail end to end")
    func mapLiftsImminentLowPriority() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Pay parking ticket", category: "Finance", priority: "low",
                                  contextTags: [], dueDate: isoUTC(day: 18, hour: 17), recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: [])],
            suggestedProject: nil)
        let result = CaptureMapper.map(extracted, now: dateUTC(day: 18), calendar: utcCalendar)
        #expect(result.tasks.first?.priority == "medium")
    }

    @Test("Tags encode to lowercased JSON; empties dropped; nil when none")
    func tagEncoding() {
        #expect(CaptureMapper.encodeTags(["Home", " Store ", ""]) == "[\"home\",\"store\"]")
        #expect(CaptureMapper.encodeTags([]) == nil)
        #expect(CaptureMapper.encodeTags(["  "]) == nil)
    }

    @Test("Novel tags are kept (open vocabulary); duplicates collapse; garbage dropped")
    func tagOpenVocabulary() {
        // New philosophy: a specific tag the old ten-word list didn't know is now welcome.
        #expect(CaptureMapper.encodeTags(["phone", "kitchen"]) == "[\"phone\",\"kitchen\"]")
        #expect(CaptureMapper.encodeTags(["school", "doctor"]) == "[\"school\",\"doctor\"]")
        #expect(CaptureMapper.encodeTags(["gym", "GYM", "gym"]) == "[\"gym\"]")
        // Light sanity bound only: a whole phrase is not a tag.
        #expect(CaptureMapper.encodeTags(["at the grocery store downtown"]) == nil)
    }

    @Test("A suggested project is trusted, even for a single meaty task")
    func suggestedProjectTrusted() {
        // New philosophy (guard #6): if Gemini confidently names a project, take it — the prompt
        // tells it not to over-organize a lone errand, so we no longer demand 2+ tasks as proof.
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Draft the pitch deck", category: "Work", priority: "high",
                                  contextTags: ["computer"], dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])],
            suggestedProject: "Series A raise"
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.project?.title == "Series A raise")
        #expect(result.tasks.first?.projectId == result.project?.id)
    }

    @Test("A suggested name with no tasks and no command makes no empty project")
    func noEmptyProjectFromNoise() {
        let extracted = ExtractedCapture(summary: nil, tasks: [], suggestedProject: "Stray name")
        let result = CaptureMapper.map(extracted, sourceText: "hmm")
        #expect(result.project == nil)
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

    // MARK: Subtask cleanup — the model decides whether to decompose; we just tidy

    @Test("A single genuinely distinct sub-step is kept — the model's call is trusted")
    func loneDistinctSubtaskKept() {
        // New philosophy: no blanket "fewer than 2 → nuke them all". A distinct step stands.
        #expect(CaptureMapper.cleanSubtasks(parentTitle: "Buy milk", subtasks: ["Go to the store"]) == ["Go to the store"])
    }

    @Test("A subtask that restates the parent errand is still dropped (real cleanup)")
    func restatingSubtaskDropped() {
        // Parent already says it; the subtask just repeats it → mechanical dedup, not judgment.
        #expect(CaptureMapper.cleanSubtasks(parentTitle: "Go to the store to buy milk",
                                            subtasks: ["Buy milk", "Go to the store"]) == [])
        #expect(CaptureMapper.cleanSubtasks(parentTitle: "Buy milk",
                                            subtasks: ["Buy milk!", "buy MILK"]) == [])
    }

    @Test("Distinct sub-steps are kept and duplicates collapse")
    func distinctSubtasksKept() {
        let kept = CaptureMapper.cleanSubtasks(parentTitle: "Go home",
                                               subtasks: ["Grab charger", "Water plants", "Grab charger"])
        #expect(kept == ["Grab charger", "Water plants"])   // duplicate collapsed
    }

    @Test("map() still drops a subtask that only restates the parent, end to end")
    func mapDropsRestatingSubtask() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy milk", category: "Personal", priority: "medium",
                                  contextTags: ["store"], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: ["Go to the store to buy milk"])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)
        #expect(result.tasks.count == 1)   // parent "Buy milk" is contained in the subtask → dropped
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
