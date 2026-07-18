import Testing
import Foundation
@testable import Offload

struct HomeGroupingTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func todayISO(hour: Int) -> String {
        let d = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: hour))!
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    @Test("Focus pins high-priority and due-today; rest grouped by category in order")
    func grouping() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 9))!

        let tasks = [
            TaskItem(title: "Urgent thing", priority: "high"),                 // Focus (priority)
            TaskItem(title: "Due today", priority: "low", dueDate: todayISO(hour: 15)), // Focus (today)
            TaskItem(title: "Work item", category: "Work", priority: "medium"),
            TaskItem(title: "Personal item", category: "Personal", priority: "low"),
            TaskItem(title: "Another work", category: "Work", priority: "low")
        ]

        let sections = HomeGrouping.sections(from: tasks, now: now, calendar: utcCalendar)
        #expect(sections.first?.title == "Focus")
        #expect(sections.first?.tasks.count == 2)

        let titles = sections.map(\.title)
        #expect(titles == ["Focus", "Work", "Personal"])   // Work before Personal by category order
        #expect(sections[1].tasks.count == 2)              // two Work items
    }

    @Test("No focus section when nothing is urgent or due today")
    func noFocus() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 9))!
        let tasks = [TaskItem(title: "Someday", category: "Ideas", priority: "low")]
        let sections = HomeGrouping.sections(from: tasks, now: now, calendar: utcCalendar)
        #expect(sections.map(\.title) == ["Ideas"])
    }
}
