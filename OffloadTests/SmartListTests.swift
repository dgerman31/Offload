import Testing
import Foundation
@testable import Offload

/// The standing questions Search opens on. Each predicate is pure, so the "12 overdue" badge
/// and the list you get when you tap it can never disagree.
struct SmartListTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int, _ hour: Int = 9) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func iso(_ day: Int, _ hour: Int = 9) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour))
    }

    private let now = { () -> Date in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
    }()

    @Test("Overdue is strictly before today, not merely earlier today")
    func overdue() {
        let yesterday = TaskItem(title: "Late", dueDate: iso(17))
        let earlierToday = TaskItem(title: "This morning", dueDate: iso(18, 8))
        #expect(SearchView.SmartList.overdue.matches(yesterday, now: now, calendar: utcCalendar))
        #expect(!SearchView.SmartList.overdue.matches(earlierToday, now: now, calendar: utcCalendar))
    }

    @Test("Today matches any hour of the current day")
    func today() {
        #expect(SearchView.SmartList.today.matches(TaskItem(title: "A", dueDate: iso(18, 23)),
                                                   now: now, calendar: utcCalendar))
        #expect(!SearchView.SmartList.today.matches(TaskItem(title: "B", dueDate: iso(19)),
                                                    now: now, calendar: utcCalendar))
    }

    @Test("This week covers the next seven days from today, excluding the past")
    func week() {
        let list = SearchView.SmartList.week
        #expect(list.matches(TaskItem(title: "Soon", dueDate: iso(21)), now: now, calendar: utcCalendar))
        #expect(list.matches(TaskItem(title: "Today", dueDate: iso(18, 15)), now: now, calendar: utcCalendar))
        #expect(!list.matches(TaskItem(title: "Past", dueDate: iso(15)), now: now, calendar: utcCalendar))
        #expect(!list.matches(TaskItem(title: "Far", dueDate: iso(30)), now: now, calendar: utcCalendar))
    }

    @Test("Unscheduled means no due date at all")
    func unscheduled() {
        #expect(SearchView.SmartList.unscheduled.matches(TaskItem(title: "Someday"),
                                                         now: now, calendar: utcCalendar))
        #expect(!SearchView.SmartList.unscheduled.matches(TaskItem(title: "Dated", dueDate: iso(20)),
                                                          now: now, calendar: utcCalendar))
    }

    @Test("Completed work only appears in the Completed list")
    func completedIsolated() {
        var done = TaskItem(title: "Finished", priority: "high", dueDate: iso(17))
        done.status = "completed"

        #expect(SearchView.SmartList.done.matches(done, now: now, calendar: utcCalendar))
        // Even though it's high priority and overdue, it's finished — it shouldn't nag.
        #expect(!SearchView.SmartList.overdue.matches(done, now: now, calendar: utcCalendar))
        #expect(!SearchView.SmartList.high.matches(done, now: now, calendar: utcCalendar))
    }

    @Test("High priority ignores scheduling entirely")
    func highPriority() {
        #expect(SearchView.SmartList.high.matches(TaskItem(title: "Urgent", priority: "high"),
                                                  now: now, calendar: utcCalendar))
        #expect(!SearchView.SmartList.high.matches(TaskItem(title: "Normal", priority: "medium"),
                                                   now: now, calendar: utcCalendar))
    }
}
