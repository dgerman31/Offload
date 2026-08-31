import Testing
import Foundation
@testable import Offload

/// What the mapper does with a kind once the model has chosen one.
///
/// These are the tests that matter most in the whole taxonomy, because the prompt asks the model
/// not to date an idea and the mapper *enforces* it. A rule that lives only in a prompt is a rule
/// that holds until the model has an off day.
struct CaptureTaxonomyTests {

    private func capture(_ tasks: [ExtractedTask], project: String? = nil, confidence: Double? = nil) -> ExtractedCapture {
        ExtractedCapture(summary: nil, tasks: tasks, suggestedProject: project, confidence: confidence)
    }

    private func item(_ kind: CaptureKind, _ title: String, due: String? = nil,
                      deadline: String? = nil, recurrence: String? = nil) -> ExtractedTask {
        ExtractedTask(kind: kind.rawValue, title: title, category: "Work", priority: "medium",
                      contextTags: [], dueDate: due, deadline: deadline,
                      recurrenceRule: recurrence, effortMinutes: 30,
                      isAppointment: false, subtasks: [])
    }

    // MARK: The rules the prompt asks for, enforced anyway

    @Test("A date on an idea is stripped, however confidently the model states it")
    func ideasAreNeverDated() throws {
        let result = CaptureMapper.map(capture([
            item(.idea, "Could run the whole thing off the topic list",
                 due: "2027-03-10T15:00:00", deadline: "2027-03-20T00:00:00", recurrence: "FREQ=WEEKLY")
        ]))
        let idea = try #require(result.tasks.first)
        #expect(idea.captureKind == .idea)
        #expect(idea.dueDate == nil)
        #expect(idea.deadline == nil)
        #expect(idea.recurrenceRule == nil)
        #expect(idea.pinned == false)
        // An idea with a due date would go overdue, and being nagged by your own thinking is the
        // failure the whole taxonomy exists to prevent.
        #expect(!idea.isPlannable)
    }

    @Test("A task keeps the date it was given")
    func tasksKeepTheirDates() throws {
        let result = CaptureMapper.map(capture([
            item(.task, "Email the PI", due: "2027-03-10T15:00:00")
        ]))
        let task = try #require(result.tasks.first)
        #expect(task.dueDate != nil)
        #expect(task.isPlannable)
    }

    @Test("Venting leaves no row at all")
    func reflectionsProduceNothing() {
        let result = CaptureMapper.map(capture([
            item(.reflection, "I am so behind on everything and it's awful"),
            item(.task, "Email the PI")
        ]))
        #expect(result.tasks.count == 1)
        #expect(result.tasks[0].title == "Email the PI")
    }

    @Test("Steps inherit their parent's kind, so an idea's parts can't be scheduled either")
    func stepsInheritKind() {
        var parent = item(.idea, "Do a step 1 review of one topic a day")
        parent.subtasks = ["Pick the topic list", "Generate a practice question"]
        let result = CaptureMapper.map(capture([parent]))
        #expect(result.tasks.count == 3)
        for task in result.tasks {
            #expect(task.captureKind == .idea)
            #expect(!task.isPlannable)
        }
    }

    // MARK: Fidelity — the difference people notice

    @Test("An idea keeps the user's wording; a task gets normalised")
    func fidelityRuleHolds() {
        let spoken = "i need to email the PI about the dataset"
        let asTask = CaptureMapper.map(capture([item(.task, spoken)])).tasks[0]
        let asIdea = CaptureMapper.map(capture([item(.idea, spoken)])).tasks[0]
        // `actionTitle` strips the "I need to" framing, which is right for something you do…
        #expect(!asTask.title.lowercased().hasPrefix("i need to"))
        // …and wrong for something you thought. The phrasing is the content.
        #expect(asIdea.title.lowercased().hasPrefix("i need to"))
    }

    @Test("A long idea is shortened for the row and kept whole in the details")
    func longIdeasSurviveIntact() {
        let long = "I could make a step 1 review of one topic a day in the morning and have it do a full thing with a practice question in order of a given topic list, and then track which ones I keep getting wrong"
        let idea = CaptureMapper.map(capture([item(.idea, long)])).tasks[0]
        #expect(idea.title.count < long.count)
        // Nothing is truncated anywhere it can't be recovered.
        #expect(idea.descriptionText == long)
    }

    @Test("Tidying an idea doesn't rewrite it")
    func keptTitleOnlyTidies() {
        #expect(CaptureMapper.keptTitle("  could   try the topic list.  ") == "Could try the topic list")
        #expect(CaptureMapper.keptTitle("I should really start reading about renal")
                == "I should really start reading about renal")
    }

    // MARK: The calendar gate

    @Test("Only a real appointment reaches the calendar")
    func calendarGate() {
        var appointment = item(.event, "Committee meeting", due: "2027-03-10T14:00:00")
        appointment.isAppointment = true
        let result = CaptureMapper.map(capture([appointment]))
        #expect(result.appointmentTaskIds.count == 1)

        // The same words as an idea can't reach the calendar, because the date was stripped first.
        var asIdea = item(.idea, "Committee meeting", due: "2027-03-10T14:00:00")
        asIdea.isAppointment = true
        #expect(CaptureMapper.map(capture([asIdea])).appointmentTaskIds.isEmpty)
    }

    // MARK: Asking when unsure

    @Test("A low-confidence capture is given a kind question the model forgot to ask")
    func lowConfidenceAsks() {
        let chips = ClarifyChip.withKindFallback([], capture: capture([item(.task, "Try the topic list")], confidence: 0.4))
        #expect(chips.count == 2)
        #expect(chips.allSatisfy { $0.group == "kind" })
        // Both sides of the real question — "is this something to do, or something I thought?"
        #expect(chips.contains { $0.action == .setKind(.task) })
        #expect(chips.contains { $0.action == .setKind(.idea) })
    }

    @Test("A confident capture is never padded with questions")
    func confidentCapturesStaySilent() {
        #expect(ClarifyChip.withKindFallback([], capture: capture([item(.task, "Buy milk")], confidence: 0.95)).isEmpty)
        // No stated confidence means the model didn't judge; that's not the same as being unsure,
        // and inventing a question there would make a working capture look doubtful.
        #expect(ClarifyChip.withKindFallback([], capture: capture([item(.task, "Buy milk")])).isEmpty)
    }

    @Test("A question the model already asked isn't asked twice")
    func existingKindChipWins() {
        let existing = [ClarifyChip(label: "Idea", action: .setKind(.idea))]
        let chips = ClarifyChip.withKindFallback(existing, capture: capture([item(.task, "x")], confidence: 0.2))
        #expect(chips.count == 1)
    }

    @Test("Tapping a kind chip takes the schedule with it")
    func kindChipClearsSchedule() {
        var task = TaskItem(title: "Try the topic list", dueDate: "2027-03-10T15:00:00", deadline: "2027-03-20T00:00:00")
        task.pinned = true
        task.recurrenceRule = "FREQ=WEEKLY"
        let patched = ClarifyChip(label: "Idea", action: .setKind(.idea)).patch(task)
        #expect(patched.captureKind == .idea)
        #expect(patched.dueDate == nil)
        #expect(patched.deadline == nil)
        #expect(patched.recurrenceRule == nil)
        #expect(patched.pinned == false)
    }

    @Test("Reclassifying back into a task doesn't invent a date")
    func kindChipDoesNotInventSchedule() {
        let idea = TaskItem(title: "Try the topic list", kind: .idea)
        let patched = ClarifyChip(label: "To do", action: .setKind(.task)).patch(idea)
        #expect(patched.captureKind == .task)
        #expect(patched.dueDate == nil)
    }
}
