import Testing
import Foundation
@testable import Offload

/// Closing out a day: what counts as done, what's left, and where the rest lands.
struct EveningShutdownTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    /// 30 July 2026 at `hour`.
    private func at(_ hour: Int, minute: Int = 0, day: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private func iso(_ hour: Int, minute: Int = 0, day: Int = 30) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: at(hour, minute: minute, day: day))
    }

    private func done(_ title: String, at hour: Int, day: Int = 30) -> TaskItem {
        var task = TaskItem(title: title)
        task.status = "completed"
        task.completedAt = iso(hour, day: day)
        return task
    }

    private func open(_ title: String, at hour: Int, day: Int = 30, allDay: Bool = false) -> TaskItem {
        var task = TaskItem(title: title, dueDate: iso(hour, day: day))
        task.dueIsAllDay = allDay
        return task
    }

    // MARK: What the day came to

    @Test("The day splits into what got done, what's left, and what's already on tomorrow")
    func summarySplitsTheDay() {
        let tasks = [
            done("Anki", at: 7),
            done("Lecture notes", at: 14),
            open("Enter REDCap data", at: 16),
            open("Email the PI", at: 18),
            open("Histology lab", at: 9, day: 31)
        ]
        let summary = EveningShutdown.summary(tasks: tasks, now: at(21), calendar: calendar)

        #expect(summary.completed.map(\.title) == ["Anki", "Lecture notes"])
        #expect(summary.unfinished.map(\.title) == ["Enter REDCap data", "Email the PI"])
        #expect(summary.tomorrow.map(\.title) == ["Histology lab"])
        #expect(summary.firstTomorrow?.title == "Histology lab")
    }

    @Test("Yesterday's finished work isn't today's credit")
    func onlyTodaysCompletions() {
        let tasks = [done("Old thing", at: 14, day: 29), done("Today's thing", at: 14)]
        let summary = EveningShutdown.summary(tasks: tasks, now: at(21), calendar: calendar)
        #expect(summary.completed.map(\.title) == ["Today's thing"])
    }

    @Test("Steps never appear on their own — rolling the parent takes them with it")
    func stepsAreNotDecisions() {
        let parent = open("Enter REDCap data", at: 16)
        var step = TaskItem(title: "Pull the export", dueDate: iso(16))
        step.parentTaskId = parent.id

        let summary = EveningShutdown.summary(tasks: [parent, step], now: at(21), calendar: calendar)
        #expect(summary.unfinished.map(\.title) == ["Enter REDCap data"])
    }

    @Test("Deleted and undated work is nobody's decision tonight")
    func ignoresDeletedAndUndated() {
        var deleted = open("Gone", at: 16)
        deleted.deleted = true
        let undated = TaskItem(title: "Someday")

        let summary = EveningShutdown.summary(tasks: [deleted, undated], now: at(21), calendar: calendar)
        #expect(summary.unfinished.isEmpty)
        #expect(summary.isEmpty)
    }

    // MARK: Where the rest goes

    @Test("An hour you chose survives the move, along with its pin")
    func timedWorkKeepsItsHour() {
        var task = open("Email the PI", at: 16)
        task.pinned = true

        let placement = EveningShutdown.tomorrowPlacement(for: task, now: at(21), calendar: calendar)
        #expect(placement.isAllDay == false)
        #expect(placement.keepsPin)
        #expect(placement.dueDate == at(16, day: 31))
    }

    @Test("Whole-day and undated work lands as a whole-day intention tomorrow")
    func flexibleWorkLandsWholeDay() {
        let wholeDay = open("Read the paper", at: 9, allDay: true)
        let placement = EveningShutdown.tomorrowPlacement(for: wholeDay, now: at(21), calendar: calendar)
        #expect(placement.isAllDay)
        #expect(placement.keepsPin == false)
        #expect(placement.dueDate == at(0, day: 31))

        let undated = TaskItem(title: "Someday")
        let second = EveningShutdown.tomorrowPlacement(for: undated, now: at(21), calendar: calendar)
        #expect(second.isAllDay)
        #expect(second.dueDate == at(0, day: 31))
    }

    @Test("Rolling forward at 11pm still means tomorrow, not the small hours of tonight")
    func lateNightRollsToTheNextDay() {
        let task = open("Email the PI", at: 16)
        let placement = EveningShutdown.tomorrowPlacement(for: task, now: at(23, minute: 45), calendar: calendar)
        #expect(placement.dueDate == at(16, day: 31))
    }

    // MARK: What it says

    @Test("The headline leads with what got done")
    func headlineLeadsWithCredit() {
        var summary = EveningShutdown.Summary()
        #expect(EveningShutdown.headline(summary) == "A quiet day.")

        summary.completed = [done("Anki", at: 7)]
        #expect(EveningShutdown.headline(summary) == "One thing done, and nothing left.")

        summary.unfinished = [open("Email the PI", at: 16), open("REDCap", at: 17)]
        #expect(EveningShutdown.headline(summary) == "One thing done, 2 still open.")

        summary.completed = []
        #expect(EveningShutdown.headline(summary) == "Nothing finished today.")
    }

    // MARK: When Home offers it

    @Test("Not offered before the evening, once it's been done, or when there's nothing to say")
    func offeringRules() {
        let defaults = UserDefaults(suiteName: "evening-shutdown-\(UUID().uuidString)")!
        let tasks = [done("Anki", at: 7), open("Email the PI", at: 16)]

        // Mid-afternoon: the day isn't over.
        #expect(EveningShutdown.shouldOffer(tasks: tasks, now: at(15), calendar: calendar,
                                            defaults: defaults) == false)
        // Evening, with something to show.
        #expect(EveningShutdown.shouldOffer(tasks: tasks, now: at(21), calendar: calendar,
                                            defaults: defaults))
        // An empty day is not worth a ceremony.
        #expect(EveningShutdown.shouldOffer(tasks: [], now: at(21), calendar: calendar,
                                            defaults: defaults) == false)

        // Once closed out, it leaves you alone — until tomorrow.
        EveningShutdown.recordClosed(now: at(21), calendar: calendar, defaults: defaults)
        #expect(EveningShutdown.alreadyClosed(now: at(22), calendar: calendar, defaults: defaults))
        #expect(EveningShutdown.shouldOffer(tasks: tasks, now: at(22), calendar: calendar,
                                            defaults: defaults) == false)
        #expect(EveningShutdown.alreadyClosed(now: at(21, day: 31), calendar: calendar,
                                              defaults: defaults) == false)
    }
}
