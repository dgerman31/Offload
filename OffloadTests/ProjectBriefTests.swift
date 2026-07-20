import Testing
import Foundation
@testable import Offload

/// The deterministic half of project briefs: the facts the model is handed, and the fallback
/// prose used when it isn't available. The model only ever writes — it never decides status.
struct ProjectBriefTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: 9))!
    }

    private func iso(_ day: Int) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day))
    }

    private let project = Project(title: "Move apartments")

    @Test("Facts roll up progress, overdue and undated work")
    func facts() {
        var done = TaskItem(title: "Book movers"); done.status = "completed"; done.completedAt = iso(16)
        let tasks = [
            done,
            TaskItem(title: "Pack kitchen", priority: "high", dueDate: iso(15)),   // overdue
            TaskItem(title: "Change address")                                       // undated
        ]
        let f = ProjectBrief.facts(project: project, tasks: tasks, now: date(18), calendar: utcCalendar)

        #expect(f.total == 3)
        #expect(f.completed == 1)
        #expect(f.remaining == 2)
        #expect(f.overdue == 1)
        #expect(f.unscheduled == 1)
        #expect(f.nextUp == "Pack kitchen")      // highest priority open task
        #expect(f.recentlyDone == ["Book movers"])
    }

    @Test("Stalled days count from the last completion, and only while work remains")
    func stalled() {
        var done = TaskItem(title: "Old win"); done.status = "completed"; done.completedAt = iso(4)
        let withRemaining = ProjectBrief.facts(
            project: project, tasks: [done, TaskItem(title: "Still to do")],
            now: date(18), calendar: utcCalendar
        )
        #expect(withRemaining.stalledDays == 14)

        // Nothing left to do isn't "stalled", it's finished.
        let allDone = ProjectBrief.facts(project: project, tasks: [done], now: date(18), calendar: utcCalendar)
        #expect(allDone.stalledDays == nil)
    }

    @Test("An empty project says so plainly")
    func emptyProject() {
        let f = ProjectBrief.facts(project: project, tasks: [], now: date(18), calendar: utcCalendar)
        #expect(f.total == 0)
        #expect(ProjectBrief.deterministicBrief(f).contains("Nothing in this project yet"))
    }

    @Test("Fallback brief leads with progress and surfaces what's wrong")
    func fallbackBrief() {
        var f = ProjectBrief.Facts(title: "Move")
        f.total = 5; f.completed = 2; f.overdue = 2; f.unscheduled = 1
        f.nextUp = "Pack kitchen"; f.stalledDays = 12

        let text = ProjectBrief.deterministicBrief(f)
        #expect(text.contains("2 of 5 done"))
        #expect(text.contains("2 tasks are overdue"))
        #expect(text.contains("12 days"))
        #expect(text.contains("Pack kitchen"))
    }

    @Test("A finished project is described as finished, with no next step")
    func finished() {
        var f = ProjectBrief.Facts(title: "Done thing")
        f.total = 3; f.completed = 3
        let text = ProjectBrief.deterministicBrief(f)
        #expect(text.contains("Everything's finished"))
        #expect(!text.contains("Next up"))
    }

    @Test("The model prompt carries only facts — never freeform task content to embroider")
    func promptIsFactual() {
        var f = ProjectBrief.Facts(title: "Move")
        f.total = 4; f.completed = 1; f.overdue = 1; f.nextUp = "Pack kitchen"
        let prompt = ProjectBrief.prompt(f)
        #expect(prompt.contains("Project: Move"))
        #expect(prompt.contains("4 total"))
        #expect(prompt.contains("Pack kitchen"))
    }
}
