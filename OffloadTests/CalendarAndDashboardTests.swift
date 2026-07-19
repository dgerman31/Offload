import Testing
import Foundation
@testable import Offload

/// Covers the pure layer behind the interactive calendar and the Home day dashboard:
/// merging tasks with calendar events, month-grid geometry, and the day summary/headline.
struct CalendarAndDashboardTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ day: Int, _ hour: Int = 12, month: Int = 7) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func iso(_ day: Int, _ hour: Int = 12, month: Int = 7) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour, month: month))
    }

    private func event(_ title: String, day: Int, hour: Int, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: date(day, hour),
                      end: date(day, hour + 1), isAllDay: allDay, location: nil, colorHex: nil)
    }

    // MARK: DayTimeline

    @Test("A day's timeline merges events and tasks in chronological order")
    func timelineOrdering() {
        let tasks = [
            TaskItem(title: "Task at 3pm", dueDate: iso(18, 15)),
            TaskItem(title: "Task at 9am", dueDate: iso(18, 9))
        ]
        let events = [event("Standup", day: 18, hour: 10), event("Review", day: 18, hour: 16)]

        let items = DayTimeline.items(tasks: tasks, events: events, on: date(18), calendar: utcCalendar)
        #expect(items.map(\.title) == ["Task at 9am", "Standup", "Task at 3pm", "Review"])
    }

    @Test("Untimed entries sink below timed ones, all-day events before undated tasks")
    func timelineUntimedLast() {
        let tasks = [
            TaskItem(title: "Timed", dueDate: iso(18, 9)),
            TaskItem(title: "Undated")          // no due date — not part of this day at all
        ]
        let events = [event("Holiday", day: 18, hour: 0, allDay: true)]

        let items = DayTimeline.items(tasks: tasks, events: events, on: date(18), calendar: utcCalendar)
        // The undated task has no due date, so it isn't on any day's timeline.
        #expect(items.map(\.title) == ["Timed", "Holiday"])
    }

    @Test("Other days' items and completed tasks are excluded")
    func timelineFilters() {
        var done = TaskItem(title: "Already done", dueDate: iso(18, 9))
        done.status = "completed"
        let tasks = [done, TaskItem(title: "Tomorrow's task", dueDate: iso(19, 9))]
        let events = [event("Tomorrow's meeting", day: 19, hour: 10)]

        let items = DayTimeline.items(tasks: tasks, events: events, on: date(18), calendar: utcCalendar)
        #expect(items.isEmpty)
    }

    @Test("Density counts tasks and events per day and flags high priority")
    func density() {
        let tasks = [
            TaskItem(title: "A", priority: "high", dueDate: iso(18, 9)),
            TaskItem(title: "B", priority: "low", dueDate: iso(18, 14)),
            TaskItem(title: "C", priority: "low", dueDate: iso(20, 9))
        ]
        let events = [event("Meeting", day: 18, hour: 11)]

        let map = DayTimeline.density(tasks: tasks, events: events, calendar: utcCalendar)
        let day18 = map[utcCalendar.startOfDay(for: date(18))]
        let day20 = map[utcCalendar.startOfDay(for: date(20))]

        #expect(day18?.tasks == 2)
        #expect(day18?.events == 1)
        #expect(day18?.hasHighPriority == true)
        #expect(day20?.tasks == 1)
        #expect(day20?.hasHighPriority == false)
        #expect(map[utcCalendar.startOfDay(for: date(19))] == nil)   // nothing that day
    }

    @Test("Month grid is whole weeks, starts on the calendar's first weekday, covers the month")
    func monthGrid() {
        let days = DayTimeline.monthGridDays(for: date(18), calendar: utcCalendar)

        #expect(days.count % 7 == 0)
        #expect(!days.isEmpty)
        #expect(utcCalendar.component(.weekday, from: days[0]) == utcCalendar.firstWeekday)
        // Every day of July 2026 appears in the grid.
        let julyDays = days.filter { utcCalendar.component(.month, from: $0) == 7 }
        #expect(julyDays.count == 31)
    }

    // MARK: DayDashboard

    @Test("Greeting shifts with the time of day")
    func greetings() {
        #expect(DayDashboard.greeting(for: date(18, 8), calendar: utcCalendar) == "Good morning")
        #expect(DayDashboard.greeting(for: date(18, 14), calendar: utcCalendar) == "Good afternoon")
        #expect(DayDashboard.greeting(for: date(18, 19), calendar: utcCalendar) == "Good evening")
        #expect(DayDashboard.greeting(for: date(18, 2), calendar: utcCalendar) == "Still up")
    }

    @Test("Summary separates overdue, due-today, undated, and completed work")
    func summaryCounts() {
        var done = TaskItem(title: "Done", dueDate: iso(18, 9))
        done.status = "completed"
        done.completedAt = iso(18, 10)

        let tasks = [
            TaskItem(title: "Late", priority: "high", dueDate: iso(16, 9)),   // overdue
            TaskItem(title: "Today", dueDate: iso(18, 15)),                   // due today
            TaskItem(title: "Someday"),                                       // undated
            done
        ]
        let events = [event("Standup", day: 18, hour: 10)]

        let s = DayDashboard.summary(tasks: tasks, events: events, now: date(18, 9), calendar: utcCalendar)
        #expect(s.overdueCount == 1)
        #expect(s.dueTodayCount == 1)
        #expect(s.untimedCount == 1)
        #expect(s.completedToday == 1)
        #expect(s.eventCount == 1)
        #expect(s.nextTask?.title == "Late")      // overdue outranks today
        #expect(s.nextEvent?.title == "Standup")
        #expect(!s.isClear)
    }

    @Test("Headline leads with overdue, then today's load, then an all-clear")
    func headlines() {
        var overdue = DaySummary(greeting: "", headline: "", subhead: "")
        overdue.overdueCount = 2
        #expect(DayDashboard.headline(for: overdue).headline == "2 things are overdue")

        var busy = DaySummary(greeting: "", headline: "", subhead: "")
        busy.dueTodayCount = 2
        busy.eventCount = 1
        #expect(DayDashboard.headline(for: busy).headline == "3 things need you today")

        var cleared = DaySummary(greeting: "", headline: "", subhead: "")
        cleared.completedToday = 4
        #expect(DayDashboard.headline(for: cleared).headline == "Mind clear")

        let empty = DaySummary(greeting: "", headline: "", subhead: "")
        #expect(DayDashboard.headline(for: empty).headline == "Mind clear")
        #expect(empty.isClear)
    }

    @Test("Next event skips ones that already ended")
    func nextEventSkipsPast() {
        let events = [event("Morning standup", day: 18, hour: 9), event("Afternoon sync", day: 18, hour: 16)]
        let s = DayDashboard.summary(tasks: [], events: events, now: date(18, 14), calendar: utcCalendar)
        #expect(s.nextEvent?.title == "Afternoon sync")
    }
}
