import Testing
import Foundation
@testable import Offload

/// Recurring routines: fixed classes occurring on their days (minus cancellations), and the
/// flexible scheduler that spends sessions on your lightest days and rests you on the busiest.
struct RoutineTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ day: Int, _ hour: Int = 8) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    // MARK: Fixed routines

    @Test("A fixed routine occurs on its weekdays and nowhere else")
    func fixedOccurrence() {
        let monday = date(20)
        let wd = utcCalendar.component(.weekday, from: monday)
        let routine = Routine(title: "Practice of Medicine", kind: .fixed, weekdays: [wd],
                              startMinute: 9 * 60, durationMinutes: 90)

        let onDay = RoutinePlanner.fixedSessions(routines: [routine], exceptions: [], on: monday, calendar: utcCalendar)
        #expect(onDay.count == 1)
        #expect(onDay[0].startMinute == 540)
        #expect(onDay[0].isFixed)

        // The next day is a different weekday — nothing.
        let nextDay = RoutinePlanner.fixedSessions(routines: [routine], exceptions: [], on: date(21), calendar: utcCalendar)
        #expect(nextDay.isEmpty)
    }

    @Test("A cancellation removes just that day's session, not the routine")
    func cancellation() {
        let monday = date(20)
        let wd = utcCalendar.component(.weekday, from: monday)
        let routine = Routine(title: "Class", kind: .fixed, weekdays: [wd], startMinute: 540)
        let exception = RoutineException(routineId: routine.id,
                                         date: RoutineException.dayKey(monday, calendar: utcCalendar))

        // Cancelled this Monday…
        #expect(RoutinePlanner.fixedSessions(routines: [routine], exceptions: [exception],
                                             on: monday, calendar: utcCalendar).isEmpty)
        // …but next week's same weekday is untouched.
        guard let nextMonday = utcCalendar.date(byAdding: .day, value: 7, to: monday) else { return }
        #expect(RoutinePlanner.fixedSessions(routines: [routine], exceptions: [exception],
                                             on: nextMonday, calendar: utcCalendar).count == 1)
    }

    @Test("Inactive routines don't occur")
    func inactive() {
        let monday = date(20)
        let wd = utcCalendar.component(.weekday, from: monday)
        let routine = Routine(title: "Old class", kind: .fixed, weekdays: [wd], active: false)
        #expect(RoutinePlanner.fixedSessions(routines: [routine], exceptions: [], on: monday, calendar: utcCalendar).isEmpty)
    }

    // MARK: Flexible scheduling

    private func gym(_ times: Int, flex: Int = 0) -> Routine {
        Routine(title: "Gym", kind: .flexible, durationMinutes: 60, timesPerWeek: times, flex: flex)
    }

    @Test("Flexible sessions land on the lightest days, resting on the busiest")
    func flexiblePicksLightDays() {
        // Mon/Wed/Fri are heavy with class; Tue/Thu are free.
        let week = [date(20), date(21), date(22), date(23), date(24)]   // Mon–Fri
        let busyness: [Date: Int] = [
            utcCalendar.startOfDay(for: date(20)): 300,   // Mon heavy
            utcCalendar.startOfDay(for: date(21)): 0,     // Tue free
            utcCalendar.startOfDay(for: date(22)): 300,   // Wed heavy
            utcCalendar.startOfDay(for: date(23)): 0,     // Thu free
            utcCalendar.startOfDay(for: date(24)): 300    // Fri heavy
        ]
        let chosen = RoutinePlanner.flexibleDays(routine: gym(2), week: week, busynessByDay: busyness,
                                                 completedDays: [], now: date(20, 6), calendar: utcCalendar)
        #expect(chosen == [utcCalendar.startOfDay(for: date(21)), utcCalendar.startOfDay(for: date(23))])
    }

    @Test("Sessions already done this week count toward the target")
    func alreadyDoneCounts() {
        let week = [date(20), date(21), date(22), date(23), date(24)]
        let busyness = Dictionary(uniqueKeysWithValues: week.map { (utcCalendar.startOfDay(for: $0), 0) })
        // Want 3, already trained Monday → only 2 more, on the earliest light days.
        let chosen = RoutinePlanner.flexibleDays(routine: gym(3), week: week, busynessByDay: busyness,
                                                 completedDays: [date(20)], now: date(20, 6), calendar: utcCalendar)
        #expect(chosen.count == 2)
        #expect(!chosen.contains(utcCalendar.startOfDay(for: date(20))))   // not the day already done
    }

    @Test("Past days of the week are never chosen")
    func onlyFutureDays() {
        let week = [date(20), date(21), date(22), date(23), date(24)]
        let busyness = Dictionary(uniqueKeysWithValues: week.map { (utcCalendar.startOfDay(for: $0), 0) })
        // It's already Thursday — only Thu and Fri remain eligible.
        let chosen = RoutinePlanner.flexibleDays(routine: gym(4), week: week, busynessByDay: busyness,
                                                 completedDays: [], now: date(23, 10), calendar: utcCalendar)
        #expect(chosen.allSatisfy { $0 >= utcCalendar.startOfDay(for: date(23)) })
        #expect(chosen.count <= 2)
    }

    @Test("The flex band lets a good week fit an extra session")
    func flexBand() {
        let week = [date(20), date(21), date(22), date(23), date(24), date(25), date(26)]
        let busyness = Dictionary(uniqueKeysWithValues: week.map { (utcCalendar.startOfDay(for: $0), 0) })
        // 4–5×: with a wide-open week, it takes the upper bound.
        let chosen = RoutinePlanner.flexibleDays(routine: gym(4, flex: 1), week: week, busynessByDay: busyness,
                                                 completedDays: [], now: date(20, 6), calendar: utcCalendar)
        #expect(chosen.count == 5)
    }

    // MARK: Busyness

    @Test("Busyness sums class time, events, and task effort for the day")
    func busynessScore() {
        let monday = date(20)
        let wd = utcCalendar.component(.weekday, from: monday)
        let routine = Routine(title: "Class", kind: .fixed, weekdays: [wd], startMinute: 540, durationMinutes: 90)
        let event = CalendarEvent(id: "e", title: "Meeting", start: date(20, 14), end: date(20, 15),
                                  isAllDay: false, location: nil, colorHex: nil)
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        let task = TaskItem(title: "Study", dueDate: f.string(from: date(20, 16)), effortMinutes: 45)

        let score = RoutinePlanner.busyness(day: monday, fixedRoutines: [routine], exceptions: [],
                                            events: [event], tasks: [task], calendar: utcCalendar)
        #expect(score == 90 + 60 + 45)
    }
}

/// Adaptive wake time.
struct WakeTrackerTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "wake-test-\(UUID().uuidString)")!
        return d
    }

    @Test("The first open of a day is the wake time; later opens don't move it")
    func firstOpenWins() {
        let defaults = freshDefaults()
        WakeTracker.recordOpen(now: date(20, 6, 30), defaults: defaults, calendar: utcCalendar)
        WakeTracker.recordOpen(now: date(20, 11, 0), defaults: defaults, calendar: utcCalendar)   // later, ignored

        #expect(WakeTracker.dayStartHour(now: date(20, 12), fallback: 9, defaults: defaults, calendar: utcCalendar) == 6)
    }

    @Test("A new day records a new wake time")
    func newDayResets() {
        let defaults = freshDefaults()
        WakeTracker.recordOpen(now: date(20, 6), defaults: defaults, calendar: utcCalendar)
        WakeTracker.recordOpen(now: date(21, 9), defaults: defaults, calendar: utcCalendar)
        #expect(WakeTracker.dayStartHour(now: date(21, 12), fallback: 8, defaults: defaults, calendar: utcCalendar) == 9)
    }

    @Test("An un-recorded day, or an odd-hour wake, falls back")
    func fallbacks() {
        let defaults = freshDefaults()
        // Nothing recorded → fallback.
        #expect(WakeTracker.dayStartHour(now: date(20, 12), fallback: 9, defaults: defaults, calendar: utcCalendar) == 9)
        // A 3am check-in is noise, not a wake time.
        WakeTracker.recordOpen(now: date(20, 3), defaults: defaults, calendar: utcCalendar)
        #expect(WakeTracker.dayStartHour(now: date(20, 12), fallback: 9, defaults: defaults, calendar: utcCalendar) == 9)
    }
}
