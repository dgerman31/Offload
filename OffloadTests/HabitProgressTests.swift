import Testing
import Foundation
@testable import Offload

/// Daily habits: what counts as done today, and when it's fair to say something about it.
struct HabitProgressTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func at(_ hour: Int, day: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private let water = Habit(id: "h-water", title: "Drink a gallon of water", sortOrder: 0)
    private let stretch = Habit(id: "h-stretch", title: "Stretch", sortOrder: 1)
    private let vitamins = Habit(id: "h-vitamins", title: "Take vitamins", sortOrder: 2)

    private func check(_ habitId: String, day: Int) -> HabitCheck {
        HabitCheck(habitId: habitId, day: HabitProgress.dayKey(at(9, day: day), calendar: calendar))
    }

    // MARK: What counts as today

    @Test("Only today's ticks count, so the list resets overnight without anything running")
    func resetsDaily() {
        let today = HabitProgress.dayKey(at(9), calendar: calendar)
        let checks = [check("h-water", day: 29), check("h-stretch", day: 30)]

        let done = HabitProgress.checkedIds(checks, on: today)
        // Yesterday's water tick is history, not a tick for today.
        #expect(done == ["h-stretch"])
    }

    @Test("A day key is the local calendar day, not a timestamp")
    func dayKeyIsADay() {
        #expect(HabitProgress.dayKey(at(0), calendar: calendar) == "2026-07-30")
        #expect(HabitProgress.dayKey(at(23), calendar: calendar) == "2026-07-30")
        #expect(HabitProgress.dayKey(at(9, day: 31), calendar: calendar) == "2026-07-31")
    }

    @Test("Progress reads as a fraction")
    func summary() {
        #expect(HabitProgress.summary(done: 0, total: 5) == "0 of 5")
        #expect(HabitProgress.summary(done: 5, total: 5) == "5 of 5")
    }

    // MARK: The nudge

    @Test("Nothing is said in the morning, however little is done")
    func silentEarly() {
        // 2 of 3 outstanding at 9am is just "morning". Saying anything here would be nagging.
        #expect(HabitProgress.nudge(habits: [water, stretch, vitamins], checkedIds: [],
                                    now: at(9), calendar: calendar) == nil)
        #expect(HabitProgress.nudge(habits: [water, stretch, vitamins], checkedIds: [],
                                    now: at(16), calendar: calendar) == nil)
    }

    @Test("Once the evening arrives, what's left gets named")
    func namesWhatIsLeft() {
        let one = HabitProgress.nudge(habits: [water, stretch], checkedIds: ["h-stretch"],
                                      now: at(18), calendar: calendar)
        #expect(one == "Drink a gallon of water still to go today.")

        let two = HabitProgress.nudge(habits: [water, stretch], checkedIds: [],
                                      now: at(18), calendar: calendar)
        #expect(two == "Drink a gallon of water and Stretch still to go today.")

        // Three or more gets counted rather than listed, so the line stays one line.
        let many = HabitProgress.nudge(habits: [water, stretch, vitamins], checkedIds: [],
                                       now: at(21), calendar: calendar)
        #expect(many == "Drink a gallon of water, Stretch and 1 more still to go today.")
    }

    @Test("Nothing is said when everything's done, or when there are no habits at all")
    func silentWhenThereIsNothingToSay() {
        #expect(HabitProgress.nudge(habits: [water, stretch],
                                    checkedIds: ["h-water", "h-stretch"],
                                    now: at(22), calendar: calendar) == nil)
        #expect(HabitProgress.nudge(habits: [], checkedIds: [],
                                    now: at(22), calendar: calendar) == nil)
    }

    @Test("The hour the nudge starts is configurable, and it's a boundary not a range")
    func nudgeHourBoundary() {
        #expect(HabitProgress.nudge(habits: [water], checkedIds: [], now: at(17),
                                    calendar: calendar, afterHour: 17) != nil)
        #expect(HabitProgress.nudge(habits: [water], checkedIds: [], now: at(16),
                                    calendar: calendar, afterHour: 17) == nil)
    }

    @Test("The starter set is a real, usable list")
    func starters() {
        let starters = HabitProgress.suggestedDefaults()
        #expect(starters.count >= 3)
        #expect(starters.contains { $0.title.localizedCaseInsensitiveContains("water") })
        #expect(starters.contains { $0.title.localizedCaseInsensitiveContains("stretch") })
        // Distinct sort orders, so the list has a stable order rather than an arbitrary one.
        #expect(Set(starters.map(\.sortOrder)).count == starters.count)
    }
}

/// The row-id-to-task-id translation that two shipped drag bugs came down to.
struct DayItemIdentityTests {

    @Test("A row id is not a task id, and can be turned back into one")
    func roundTrip() {
        let task = TaskItem(title: "Enter REDCap data")
        let item = DayItem.task(task)
        // The prefix is the whole hazard: `item.id` looks like an id and isn't the task's.
        #expect(item.id == "task-\(task.id)")
        #expect(item.id != task.id)
        #expect(DayItem.taskId(fromItemID: item.id) == task.id)
        #expect(item.taskId == task.id)
    }

    @Test("An event's row id yields no task id")
    func eventsHaveNoTask() {
        let event = CalendarEvent(id: "evt-1", title: "Lecture", start: Date(),
                                 end: Date().addingTimeInterval(3600), isAllDay: false,
                                 location: nil, colorHex: nil)
        let item = DayItem.event(event)
        #expect(item.id == "event-evt-1")
        #expect(item.taskId == nil)
        #expect(DayItem.taskId(fromItemID: item.id) == nil)
    }

    @Test("A bare task id isn't mistaken for a row id")
    func rawIdIsRejected() {
        // This is what the buggy code was effectively doing in reverse — comparing a row id
        // against raw task ids and silently never matching.
        #expect(DayItem.taskId(fromItemID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301") == nil)
    }
}
