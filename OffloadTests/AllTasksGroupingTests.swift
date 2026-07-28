import Testing
import Foundation
@testable import Offload

struct AllTasksGroupingTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-07-18 09:00 UTC, a Saturday — the fixed "now" every test anchors to.
    private var now: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 9))!
    }

    private func dueISO(day: Int, hour: Int = 12) -> String {
        let d = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    @Test("Buckets land in Overdue, Today, Tomorrow, This week, Later, Anytime, in that order")
    func fullOrdering() {
        let tasks = [
            TaskItem(title: "Late bill", dueDate: dueISO(day: 16)),        // overdue
            TaskItem(title: "Due today", dueDate: dueISO(day: 18, hour: 15)),
            TaskItem(title: "Due tomorrow", dueDate: dueISO(day: 19)),
            TaskItem(title: "This week", dueDate: dueISO(day: 22)),
            TaskItem(title: "Way out", dueDate: dueISO(day: 40)),
            TaskItem(title: "No date")
        ]
        let sections = AllTasksGrouping.sections(from: tasks, now: now, calendar: utcCalendar)
        #expect(sections.map(\.title) == ["Overdue", "Today", "Tomorrow", "This week", "Later", "Anytime"])
        #expect(sections[0].tasks.map(\.title) == ["Late bill"])
        #expect(sections[1].tasks.map(\.title) == ["Due today"])
        #expect(sections[2].tasks.map(\.title) == ["Due tomorrow"])
        #expect(sections[3].tasks.map(\.title) == ["This week"])
        #expect(sections[4].tasks.map(\.title) == ["Way out"])
        #expect(sections[5].tasks.map(\.title) == ["No date"])
    }

    @Test("Empty buckets don't produce empty sections")
    func skipsEmptyBuckets() {
        let tasks = [TaskItem(title: "Someday")]
        let sections = AllTasksGrouping.sections(from: tasks, now: now, calendar: utcCalendar)
        #expect(sections.map(\.title) == ["Anytime"])
    }

    @Test("A task due later today is Today, not Overdue")
    func laterTodayIsTodayNotOverdue() {
        let tasks = [TaskItem(title: "This afternoon", dueDate: dueISO(day: 18, hour: 20))]
        let sections = AllTasksGrouping.sections(from: tasks, now: now, calendar: utcCalendar)
        #expect(sections.map(\.title) == ["Today"])
    }

    @Test("A step with a live parent nests under it instead of getting its own row")
    func stepsNestUnderParent() {
        let parent = TaskItem(title: "Ship the poster", dueDate: dueISO(day: 18, hour: 15))
        let step = TaskItem(title: "print it", parentTaskId: parent.id, dueDate: dueISO(day: 18, hour: 16))
        let sections = AllTasksGrouping.sections(from: [parent, step], now: now, calendar: utcCalendar)
        let today = sections.first { $0.title == "Today" }!
        #expect(today.rows.map(\.task.title) == ["Ship the poster", "print it"])
        #expect(today.rows.map(\.indented) == [false, true])
    }

    @Test("A step whose parent is gone is promoted rather than disappearing")
    func orphanedStepIsPromoted() {
        let orphan = TaskItem(title: "print it", parentTaskId: "gone", dueDate: dueISO(day: 18))
        let sections = AllTasksGrouping.sections(from: [orphan], now: now, calendar: utcCalendar)
        #expect(sections.first { $0.title == "Today" }?.tasks.map(\.title) == ["print it"])
    }

    @Test("Within a bucket, tasks still order by urgency (priority, then soonest due date)")
    func withinBucketOrdering() {
        let tasks = [
            TaskItem(title: "Medium", priority: "medium", dueDate: dueISO(day: 23)),
            TaskItem(title: "High", priority: "high", dueDate: dueISO(day: 24)),
            TaskItem(title: "Low", priority: "low", dueDate: dueISO(day: 21))
        ]
        let sections = AllTasksGrouping.sections(from: tasks, now: now, calendar: utcCalendar)
        let thisWeek = sections.first { $0.title == "This week" }!
        #expect(thisWeek.tasks.map(\.title) == ["High", "Medium", "Low"])
    }
}
