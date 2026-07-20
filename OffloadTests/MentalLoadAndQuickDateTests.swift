import Testing
import Foundation
@testable import Offload

/// The mental-load metric and the type-ahead date parser.
struct MentalLoadAndQuickDateTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ day: Int, _ hour: Int = 9) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func iso(_ day: Int, _ hour: Int = 9) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour))
    }

    // MARK: Mental load

    @Test("An empty list is a clear mind, scoring zero")
    func emptyIsClear() {
        let load = MentalLoad.compute(tasks: [], now: date(18), calendar: utcCalendar)
        #expect(load.score == 0)
        #expect(load.band == .clear)
        #expect(load.openLoops == 0)
    }

    @Test("Completed and deleted work doesn't weigh on you")
    func finishedWorkDoesNotCount() {
        var done = TaskItem(title: "Done"); done.status = "completed"
        var gone = TaskItem(title: "Gone"); gone.deleted = true
        let load = MentalLoad.compute(tasks: [done, gone], now: date(18), calendar: utcCalendar)
        #expect(load.openLoops == 0)
        #expect(load.score == 0)
    }

    @Test("Overdue work weighs far more than the same amount scheduled ahead")
    func overdueWeighsMost() {
        let overdue = (1...3).map { TaskItem(title: "Late \($0)", dueDate: iso(15)) }
        let future = (1...3).map { TaskItem(title: "Later \($0)", dueDate: iso(25)) }

        let heavy = MentalLoad.compute(tasks: overdue, now: date(18), calendar: utcCalendar)
        let light = MentalLoad.compute(tasks: future, now: date(18), calendar: utcCalendar)

        #expect(heavy.overdue == 3)
        #expect(heavy.score > light.score * 2)
    }

    @Test("Undated work counts as loose and is called out in the advice")
    func unscheduledCounted() {
        let tasks = (1...6).map { TaskItem(title: "Someday \($0)") }
        let load = MentalLoad.compute(tasks: tasks, now: date(18), calendar: utcCalendar)
        #expect(load.unscheduled == 6)
        #expect(load.openLoops == 6)
        #expect(load.score > 0)
    }

    @Test("Score is capped and bands escalate in order")
    func bandsEscalate() {
        let many = (1...80).map { TaskItem(title: "T\($0)", priority: "high", dueDate: iso(10)) }
        let load = MentalLoad.compute(tasks: many, now: date(18), calendar: utcCalendar)
        #expect(load.score == 100)      // capped, never runaway
        #expect(load.band == .heavy)
        #expect(!load.headline.isEmpty)
        #expect(!load.advice.isEmpty)
    }

    // MARK: Quick date

    @Test("A date phrase is lifted out and the title keeps the rest")
    func parsesTomorrow() throws {
        let match = try #require(QuickDate.parse("lunch with Sam tomorrow"))
        #expect(match.cleanedTitle == "lunch with Sam")
    }

    @Test("Times are recognised as times, bare days aren't")
    func timeDetection() throws {
        #expect(QuickDate.mentionsTime("tomorrow 1pm"))
        #expect(QuickDate.mentionsTime("at 14:30"))
        #expect(QuickDate.mentionsTime("this evening"))
        #expect(!QuickDate.mentionsTime("tomorrow"))
        #expect(!QuickDate.mentionsTime("next friday"))
    }

    @Test("Text with no date is left completely alone")
    func noDate() {
        #expect(QuickDate.parse("buy milk") == nil)
        #expect(QuickDate.parse("") == nil)
        #expect(QuickDate.parse("a") == nil)
    }

    @Test("Dangling connectives left by the removal are tidied away")
    func tidying() {
        #expect(QuickDate.tidy("call the dentist on") == "call the dentist")
        #expect(QuickDate.tidy("submit the form by  ") == "submit the form")
        #expect(QuickDate.tidy("standup at,") == "standup")
        #expect(QuickDate.tidy("water plants") == "water plants")
    }

    @Test("A bare number isn't treated as a time — it's usually part of the title")
    func bareNumberIgnored() {
        // "call 3" should stay a title, not become 3 o'clock.
        #expect(QuickDate.parse("call 3") == nil)
    }
}
