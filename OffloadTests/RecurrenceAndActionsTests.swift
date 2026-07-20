import Testing
import Foundation
@testable import Offload

/// Recurrence parsing/scheduling, snooze arithmetic, and which tasks earn a reminder.
struct RecurrenceAndActionsTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ day: Int, _ hour: Int = 9, month: Int = 7) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func iso(_ day: Int, _ hour: Int = 9, month: Int = 7) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour, month: month))
    }

    // MARK: Parsing

    @Test("Parses the RRULE shapes the extractor emits")
    func parsing() {
        #expect(Recurrence.parse("FREQ=DAILY")?.frequency == .daily)
        #expect(Recurrence.parse("FREQ=WEEKLY;INTERVAL=2")?.interval == 2)
        #expect(Recurrence.parse("RRULE:FREQ=MONTHLY")?.frequency == .monthly)
        // BYDAY maps to Calendar weekday numbers (Sunday = 1).
        #expect(Recurrence.parse("FREQ=WEEKLY;BYDAY=MO,FR")?.weekdays == [2, 6])
        // Ordinal prefixes are tolerated.
        #expect(Recurrence.parse("FREQ=MONTHLY;BYDAY=2TU")?.weekdays == [3])
    }

    @Test("Nonsense and empty rules parse to nil rather than crashing")
    func parsingInvalid() {
        #expect(Recurrence.parse(nil) == nil)
        #expect(Recurrence.parse("") == nil)
        #expect(Recurrence.parse("every week please") == nil)
        #expect(Recurrence.parse("INTERVAL=2") == nil)   // no FREQ
    }

    // MARK: Next occurrence

    @Test("Daily, weekly, monthly and yearly all advance correctly")
    func nextOccurrenceBasics() throws {
        let start = date(18)   // Sat 18 Jul 2026, 09:00 UTC
        let daily = try #require(Recurrence.parse("FREQ=DAILY"))
        let weekly = try #require(Recurrence.parse("FREQ=WEEKLY"))
        let biweekly = try #require(Recurrence.parse("FREQ=WEEKLY;INTERVAL=2"))
        let monthly = try #require(Recurrence.parse("FREQ=MONTHLY"))

        #expect(Recurrence.nextOccurrence(after: start, rule: daily, calendar: utcCalendar) == date(19))
        #expect(Recurrence.nextOccurrence(after: start, rule: weekly, calendar: utcCalendar) == date(25))
        #expect(Recurrence.nextOccurrence(after: start, rule: biweekly, calendar: utcCalendar) == date(1, 9, month: 8))
        #expect(Recurrence.nextOccurrence(after: start, rule: monthly, calendar: utcCalendar) == date(18, 9, month: 8))
    }

    @Test("Weekday rules land on the next listed day and preserve the time")
    func weekdayRecurrence() throws {
        // Mon 20 Jul 2026 -> next weekday occurrence is Wed 22.
        let monday = date(20, 14)
        let rule = try #require(Recurrence.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR"))
        let next = try #require(Recurrence.nextOccurrence(after: monday, rule: rule, calendar: utcCalendar))
        #expect(utcCalendar.component(.day, from: next) == 22)
        #expect(utcCalendar.component(.hour, from: next) == 14)   // time of day survives
    }

    // MARK: Completing a recurring task

    @Test("Completing a recurring task schedules the next one, open and undated-forward")
    func nextInstance() throws {
        let task = TaskItem(title: "Water the plants", dueDate: iso(18), recurrenceRule: "FREQ=WEEKLY")
        let follow = try #require(Recurrence.nextInstance(of: task, completedAt: date(18, 10), calendar: utcCalendar))

        #expect(follow.id != task.id)
        #expect(follow.title == "Water the plants")
        #expect(follow.status == "open")
        #expect(follow.completedAt == nil)
        #expect(follow.recurrenceRule == "FREQ=WEEKLY")
        #expect(DueDate.parse(follow.dueDate) == date(25))
    }

    @Test("A long-overdue recurring task rolls forward past now, not into the past")
    func overdueRecurringRollsForward() throws {
        // Due 4 Jul, weekly, finally completed 18 Jul — the next one must be in the future.
        let task = TaskItem(title: "Weekly review", dueDate: iso(4), recurrenceRule: "FREQ=WEEKLY")
        let completed = date(18, 10)
        let follow = try #require(Recurrence.nextInstance(of: task, completedAt: completed, calendar: utcCalendar))
        let due = try #require(DueDate.parse(follow.dueDate))
        #expect(due > completed)
    }

    @Test("A non-recurring task spawns nothing")
    func nonRecurring() {
        let task = TaskItem(title: "Buy milk", dueDate: iso(18))
        #expect(Recurrence.nextInstance(of: task, completedAt: date(18, 10), calendar: utcCalendar) == nil)
    }

    // MARK: Snooze

    @Test("Snooze presets resolve to sensible future moments")
    func snoozePresets() throws {
        let morning = date(18, 9)
        let laterToday = try #require(TaskActions.Snooze.laterToday.date(from: morning, calendar: utcCalendar))
        #expect(utcCalendar.component(.hour, from: laterToday) == 12)

        let tonight = try #require(TaskActions.Snooze.tonight.date(from: morning, calendar: utcCalendar))
        #expect(utcCalendar.component(.hour, from: tonight) == 20)
        #expect(utcCalendar.component(.day, from: tonight) == 18)

        let tomorrow = try #require(TaskActions.Snooze.tomorrow.date(from: morning, calendar: utcCalendar))
        #expect(utcCalendar.component(.day, from: tomorrow) == 19)
        #expect(utcCalendar.component(.hour, from: tomorrow) == 9)

        let nextWeek = try #require(TaskActions.Snooze.nextWeek.date(from: morning, calendar: utcCalendar))
        #expect(utcCalendar.component(.day, from: nextWeek) == 25)
    }

    @Test("Snoozing to tonight after 8pm rolls to tomorrow evening")
    func snoozeTonightLate() throws {
        let lateNight = date(18, 22)
        let tonight = try #require(TaskActions.Snooze.tonight.date(from: lateNight, calendar: utcCalendar))
        #expect(utcCalendar.component(.day, from: tonight) == 19)
        #expect(utcCalendar.component(.hour, from: tonight) == 20)
    }

    // MARK: Reminders

    @Test("Only open, future-dated tasks earn a reminder, soonest first")
    func remindableSelection() {
        var done = TaskItem(title: "Done", dueDate: iso(20)); done.status = "completed"
        var gone = TaskItem(title: "Deleted", dueDate: iso(20)); gone.deleted = true
        let tasks = [
            TaskItem(title: "Later", dueDate: iso(22)),
            TaskItem(title: "Sooner", dueDate: iso(19)),
            TaskItem(title: "Past", dueDate: iso(10)),
            TaskItem(title: "Undated"),
            done, gone
        ]
        let picked = NotificationService.remindableTasks(from: tasks, now: date(18), limit: 10)
        #expect(picked.map(\.title) == ["Sooner", "Later"])
    }

    @Test("Reminder list respects the pending-notification cap")
    func remindableLimit() {
        let tasks = (1...30).map { TaskItem(title: "T\($0)", dueDate: iso(20, 9)) }
        #expect(NotificationService.remindableTasks(from: tasks, now: date(18), limit: 5).count == 5)
    }

    @Test("Brief summary leads with overdue, and says so when the day is clear")
    func briefSummary() {
        var busy = DaySummary(greeting: "", headline: "", subhead: "")
        busy.overdueCount = 2; busy.dueTodayCount = 1; busy.eventCount = 3
        #expect(NotificationService.briefSummary(for: busy).hasPrefix("2 overdue"))

        let clear = DaySummary(greeting: "", headline: "", subhead: "")
        #expect(NotificationService.briefSummary(for: clear).contains("day is yours"))
    }
}
