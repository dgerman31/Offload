import Testing
import Foundation
@testable import Offload

/// How a project arranges itself, and what the hill says about it.
struct ProjectWorkspaceTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func at(_ day: Int, month: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func iso(_ day: Int, month: Int = 7) -> String {
        ISO8601DateFormatter().string(from: at(day, month: month))
    }

    private func row(_ kind: CaptureKind, _ title: String, order: Double? = nil, done: Bool = false) -> TaskItem {
        var task = TaskItem(title: title, sortOrder: order, kind: kind)
        if done {
            task.status = "completed"
            task.completedAt = iso(20)
        }
        return task
    }

    // MARK: Sections

    @Test("Contents group by kind, actions first and notes last")
    func sectionsAreGroupedAndOrdered() {
        let sections = ProjectBoard.sections([
            row(.note, "Ethics number is 2026-114"),
            row(.idea, "Could run it off the topic list"),
            row(.task, "Email the PI"),
            row(.question, "Do we need consent forms?"),
            row(.waiting, "Dr. Okafor — signed form")
        ])
        #expect(sections.map(\.title) == ["Next actions", "Waiting on", "Open questions", "Ideas", "Notes"])
    }

    @Test("Tasks and commitments share the Next actions heading")
    func commitmentsJoinTheActions() {
        let sections = ProjectBoard.sections([
            row(.task, "Email the PI"),
            row(.commitment, "Send Sam the draft")
        ])
        #expect(sections.count == 1)
        #expect(sections[0].items.count == 2)
    }

    @Test("Finished work leaves the sections and appears in Done")
    func doneLeavesTheBoard() {
        let tasks = [
            row(.task, "Email the PI", done: true),
            row(.task, "Pull the data")
        ]
        #expect(ProjectBoard.sections(tasks).flatMap(\.items).map(\.title) == ["Pull the data"])
        #expect(ProjectBoard.done(tasks).map(\.title) == ["Email the PI"])
    }

    @Test("A note is never in the Done pile, because a note is never done")
    func notesAreNotProgress() {
        var note = row(.note, "Ethics number is 2026-114")
        note.status = "completed"      // shouldn't be possible from the UI, must not mislead if it is
        #expect(ProjectBoard.done([note]).isEmpty)
    }

    @Test("Steps sit inside their parent, not beside it")
    func stepsAreNotLooseRows() {
        let parent = row(.task, "Write the abstract")
        var step = row(.task, "Draft the methods")
        step.parentTaskId = parent.id
        let items = ProjectBoard.sections([parent, step]).flatMap(\.items)
        #expect(items.map(\.title) == ["Write the abstract"])
    }

    @Test("An orphaned step is promoted rather than lost")
    func orphansSurvive() {
        var step = row(.task, "Draft the methods")
        step.parentTaskId = "a-parent-that-is-gone"
        #expect(ProjectBoard.sections([step]).flatMap(\.items).count == 1)
    }

    // MARK: The next action

    @Test("The next action is the top of Next actions, and manual order decides it")
    func nextActionFollowsManualOrder() {
        let tasks = [
            row(.task, "Email the PI", order: 2),
            row(.task, "Pull the data", order: 1),
            row(.idea, "Could run it off the topic list", order: 0)
        ]
        // The idea sorts first overall but is not an action, so it can never be the next action.
        #expect(ProjectBoard.nextAction(tasks)?.title == "Pull the data")
    }

    @Test("A project of nothing but ideas has no next action")
    func nextActionCanBeNothing() {
        #expect(ProjectBoard.nextAction([row(.idea, "One"), row(.note, "Two")]) == nil)
    }

    @Test("Ideas don't count as work outstanding")
    func openWorkExcludesThinking() {
        let tasks = [row(.task, "Email the PI")] + (0..<10).map { row(.idea, "Idea \($0)") }
        #expect(ProjectBoard.openWorkCount(tasks) == 1)
    }

    // MARK: Runway

    @Test("Runway says the most useful true thing, and nothing when there's nothing to say")
    func runwayText() {
        let dated = Project(title: "Chart review", dueDate: iso(25))
        #expect(ProjectBoard.runway(dated, tasks: [row(.task, "Pull the data")],
                                    now: at(20), calendar: calendar) == "5 days left · 1 to do")
        #expect(ProjectBoard.runway(dated, tasks: [], now: at(26), calendar: calendar) == "Target date passed")
        #expect(ProjectBoard.runway(Project(title: "Loose"), tasks: [], now: at(20), calendar: calendar) == nil)
    }

    // MARK: The hill

    @Test("The hill reads as figuring-out below the crest and executing above it")
    func hillLabels() {
        #expect(ProjectHill.label(nil) == "Not tracked")
        #expect(ProjectHill.label(0.2) == "Figuring it out")
        #expect(ProjectHill.label(0.8) == "Executing")
        #expect(ProjectHill.advice(0.2)?.contains("think") == true)
        #expect(ProjectHill.advice(0.8)?.contains("calendar") == true)
        #expect(ProjectHill.advice(nil) == nil)
    }

    @Test("A project that hasn't moved in three weeks is stalled")
    func stalledDetection() {
        #expect(ProjectHill.isStalled(hill: 0.3, hillUpdatedAt: iso(1), now: at(25), calendar: calendar))
        #expect(!ProjectHill.isStalled(hill: 0.3, hillUpdatedAt: iso(20), now: at(25), calendar: calendar))
    }

    @Test("Neither an untracked project nor a finished one is stuck")
    func stalledNeedsAPosition() {
        #expect(!ProjectHill.isStalled(hill: nil, hillUpdatedAt: iso(1), now: at(25), calendar: calendar))
        #expect(!ProjectHill.isStalled(hill: 1.0, hillUpdatedAt: iso(1), now: at(25), calendar: calendar))
        // Never moved at all: there's no history to call stale.
        #expect(!ProjectHill.isStalled(hill: 0.3, hillUpdatedAt: nil, now: at(25), calendar: calendar))
    }

    @Test("Positions from a drag are clamped into range")
    func clamping() {
        #expect(ProjectHill.clamp(-0.4) == 0)
        #expect(ProjectHill.clamp(1.7) == 1)
        #expect(ProjectHill.clamp(0.42) == 0.42)
    }
}
