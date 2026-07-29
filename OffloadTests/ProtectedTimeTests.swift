import Testing
import Foundation
@testable import Offload

/// Hours the planner must leave alone, and the arithmetic that keeps them out of free time.
struct ProtectedTimeTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    /// 2026-07-29 is a Wednesday (weekday 4).
    private func day(_ dayOfMonth: Int = 29) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: dayOfMonth))!
    }

    private func at(_ hour: Int, _ minute: Int = 0, dayOfMonth: Int = 29) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: dayOfMonth,
                                           hour: hour, minute: minute))!
    }

    private func block(_ title: String, weekdays: Set<Int>, from: Int, to: Int) -> ProtectedBlock {
        ProtectedBlock(title: title, weekdays: weekdays,
                       startMinute: from * 60, endMinute: to * 60, kind: .study)
    }

    @Test("A block expands into a busy interval only on the weekdays it covers")
    func expandsOnMatchingWeekdaysOnly() {
        let study = block("Study", weekdays: [4], from: 19, to: 21)   // Wednesdays

        let onWednesday = ProtectedTime.busyBlocks(on: day(29), blocks: [study], calendar: calendar)
        #expect(onWednesday.count == 1)
        #expect(onWednesday[0].start == at(19))
        #expect(onWednesday[0].end == at(21))

        // Thursday the 30th isn't covered.
        #expect(ProtectedTime.busyBlocks(on: day(30), blocks: [study], calendar: calendar).isEmpty)
    }

    @Test("Disabled and zero-length blocks reserve nothing")
    func ignoredBlocks() {
        var off = block("Study", weekdays: [4], from: 19, to: 21)
        off.isEnabled = false
        let backwards = block("Broken", weekdays: [4], from: 21, to: 19)
        let empty = block("Empty", weekdays: [4], from: 19, to: 19)
        #expect(ProtectedTime.busyBlocks(on: day(29), blocks: [off, backwards, empty],
                                         calendar: calendar).isEmpty)
    }

    @Test("Protected blocks are identifiable as such, so nothing treats them as real events")
    func taggedIds() {
        let study = block("Study", weekdays: [4], from: 19, to: 21)
        let events = ProtectedTime.busyBlocks(on: day(29), blocks: [study], calendar: calendar)
        #expect(ProtectedTime.isProtected(eventId: events[0].id))
        #expect(ProtectedTime.isProtected(eventId: "some-real-eventkit-id") == false)
    }

    @Test("Free time excludes protected hours")
    func freeSlotsAvoidProtectedTime() {
        let study = block("Study", weekdays: [4], from: 19, to: 21)
        let busy = ProtectedTime.busyBlocks(on: day(29), blocks: [study], calendar: calendar)

        let slots = DayPlanner.freeSlots(events: busy, on: day(29), now: at(9),
                                         calendar: calendar, dayStartHour: 9, dayEndHour: 22)
        // 9am–7pm open, 7–9pm reserved, 9–10pm open again.
        #expect(slots.contains { $0.start == at(9) && $0.end == at(19) })
        #expect(slots.contains { $0.start == at(21) && $0.end == at(22) })
        #expect(slots.allSatisfy { $0.start >= at(21) || $0.end <= at(19) })
    }

    @Test("Auto-fit schedules around protected time instead of through it")
    func autoFitRespectsProtectedTime() {
        let study = block("Study", weekdays: [4], from: 9, to: 17)   // most of the day reserved
        let task = TaskItem(title: "Draft the abstract", effortMinutes: 60)

        let fitted = AutoFit.fitIntoToday(new: [task], existing: [], now: at(8),
                                          calendar: calendar, startHour: 8, cutoffHour: 21,
                                          protected: [study])
        let start = DueDate.parse(fitted[0].dueDate)
        #expect(start != nil)
        // The only real gaps are 8–9am and 5–9pm; an hour of work fits the first.
        #expect(start == at(8))
    }

    @Test("Auto-fit honours a day that starts before 9am")
    func autoFitUsesTheRealDayStart() {
        // The bug this fixes: the day-start preference was never threaded into auto-fit, so it
        // always searched from `defaultDayStartHour` (9am) and a 6am start bought nothing.
        let task = TaskItem(title: "Morning reading", effortMinutes: 30)
        let fitted = AutoFit.fitIntoToday(new: [task], existing: [], now: at(6),
                                          calendar: calendar, startHour: 6, cutoffHour: 21)
        #expect(DueDate.parse(fitted[0].dueDate) == at(6))
    }

    @Test("Weekday sets read the way people say them")
    func weekdayDescriptions() {
        #expect(ProtectedTime.describe([1, 2, 3, 4, 5, 6, 7], calendar: calendar) == "Every day")
        #expect(ProtectedTime.describe([2, 3, 4, 5, 6], calendar: calendar) == "Weekdays")
        #expect(ProtectedTime.describe([1, 7], calendar: calendar) == "Weekends")
        #expect(ProtectedTime.describe([], calendar: calendar) == "Never")
    }

    @Test("Blocks round-trip through storage")
    func storageRoundTrip() {
        let defaults = UserDefaults(suiteName: "protected-time-tests-\(UUID().uuidString)")!
        #expect(ProtectedTime.stored(defaults: defaults).isEmpty)

        let blocks = ProtectedTime.suggestedDefaults()
        ProtectedTime.save(blocks, defaults: defaults)
        let loaded = ProtectedTime.stored(defaults: defaults)
        #expect(loaded == blocks)
        #expect(loaded.contains { $0.kind == .gym })
    }
}

/// Focus history — the comparison between what work was estimated to take and what it took.
struct TaskSessionTests {

    private func session(planned: Int, actual: Int, category: String? = nil,
                         completed: Bool = true) -> TaskSession {
        TaskSession(taskId: UUID().uuidString, category: category,
                    startedAt: "2026-07-29T09:00:00Z", endedAt: "2026-07-29T10:00:00Z",
                    plannedMinutes: planned, actualMinutes: actual, ranToCompletion: completed)
    }

    @Test("Drift stays nil until there's enough history to mean anything")
    func needsASample() {
        let few = (0..<4).map { _ in session(planned: 30, actual: 45) }
        #expect(TaskSessionLog.drift(few) == nil)
        #expect(TaskSessionLog.drift(few + [session(planned: 30, actual: 45)]) == 1.5)
    }

    @Test("One runaway session can't rewrite every estimate")
    func medianNotMean() {
        // Four honest sessions and one timer left running through lunch. The mean would be ~2.2;
        // the median says what's actually true, which is that work runs about a quarter long.
        // Ratios chosen to be exactly representable, so this asserts the rule rather than
        // floating-point luck.
        let sessions = [
            session(planned: 40, actual: 50),
            session(planned: 60, actual: 75),
            session(planned: 20, actual: 25),
            session(planned: 80, actual: 100),
            session(planned: 30, actual: 180)
        ]
        #expect(TaskSessionLog.drift(sessions) == 1.25)
    }

    @Test("Sessions stopped early are excluded")
    func abandonedSessionsIgnored() {
        let abandoned = (0..<6).map { _ in session(planned: 60, actual: 5, completed: false) }
        #expect(TaskSessionLog.drift(abandoned) == nil)

        let mixed = abandoned + (0..<5).map { _ in session(planned: 30, actual: 45) }
        #expect(TaskSessionLog.drift(mixed) == 1.5)
    }

    @Test("A category with its own history uses it; one without falls back to the overall figure")
    func perCategoryDrift() {
        let work = (0..<5).map { _ in session(planned: 60, actual: 90, category: "Work") }
        let personal = (0..<5).map { _ in session(planned: 30, actual: 30, category: "Personal") }
        let all = work + personal

        #expect(TaskSessionLog.drift(all, category: "Work") == 1.5)
        #expect(TaskSessionLog.drift(all, category: "Personal") == 1.0)
        // "Health" has no sessions of its own, so it inherits the overall median.
        #expect(TaskSessionLog.drift(all, category: "Health") == TaskSessionLog.drift(all))
    }

    @Test("Nothing at all yields nothing")
    func empty() {
        #expect(TaskSessionLog.drift([]) == nil)
        #expect(TaskSessionLog.drift([], category: "Work") == nil)
    }
}
