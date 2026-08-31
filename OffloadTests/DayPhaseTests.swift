import Testing
import Foundation
@testable import Offload

/// Which of the four Home screens the clock picks, and the two places a decision overrides it.
///
/// Worth testing properly rather than observing: three of the boundaries only happen once a day
/// each, and one of them happens while you're asleep.
struct DayPhaseTests {

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

    private func phase(_ hour: Int, minute: Int = 0, planned: String = "", closed: String = "") -> DayPhase {
        DayPhase.current(now: at(hour, minute: minute), plannedDay: planned, closedDay: closed, calendar: calendar)
    }

    private func key(_ day: Int) -> String {
        WakeTracker.dayKey(at(9, day: day), calendar: calendar)
    }

    // MARK: The clock

    @Test("Each hour of the day maps to exactly one screen")
    func hoursMapToPhases() {
        #expect(phase(0) == .night)
        #expect(phase(4, minute: 59) == .night)
        #expect(phase(5) == .morning)
        #expect(phase(11, minute: 59) == .morning)
        #expect(phase(12) == .midday)
        #expect(phase(19, minute: 59) == .midday)
        #expect(phase(20) == .evening)
        #expect(phase(21, minute: 59) == .evening)
        #expect(phase(22) == .night)
        #expect(phase(23, minute: 59) == .night)
    }

    @Test("The evening opens at exactly the hour the shutdown card does")
    func eveningMatchesShutdown() {
        // Two constants for one idea is how they drift apart, so this pins them together.
        #expect(DayPhase.eveningStartHour == EveningShutdown.opensAfterHour)
    }

    // MARK: Decisions, not just hours

    @Test("Planning the day ends the morning early")
    func planningEndsTheMorning() {
        #expect(phase(6, minute: 40) == .morning)
        #expect(phase(6, minute: 40, planned: key(30)) == .midday)
    }

    @Test("Yesterday's plan doesn't end this morning")
    func yesterdaysPlanDoesNotCarry() {
        #expect(phase(7, planned: key(29)) == .morning)
    }

    @Test("Planning has no say outside the morning window")
    func planningOnlyAffectsTheMorning() {
        #expect(phase(20, planned: key(30)) == .evening)
        #expect(phase(23, planned: key(30)) == .night)
    }

    @Test("Closing out the day ends the evening early")
    func closingEndsTheEvening() {
        #expect(phase(20, minute: 15) == .evening)
        #expect(phase(20, minute: 15, closed: key(30)) == .night)
    }

    @Test("Yesterday's shutdown doesn't skip tonight's")
    func yesterdaysShutdownDoesNotCarry() {
        #expect(phase(21, closed: key(29)) == .evening)
    }

    @Test("A closed day can't strand you before the evening")
    func closingDoesNotAffectDaytime() {
        // Closing out at 8pm and still being up at 9am the next morning is the ordinary case; the
        // stale key must not turn the morning into a wind-down screen.
        #expect(phase(9, closed: key(29)) == .morning)
        #expect(phase(14, closed: key(30)) == .midday)
    }

    // MARK: Presentation

    @Test("Every phase carries a title and a symbol")
    func everyPhaseIsPresentable() {
        for option in DayPhase.allCases {
            #expect(!option.title.isEmpty)
            #expect(!option.symbol.isEmpty)
        }
        #expect(Set(DayPhase.allCases.map(\.title)).count == DayPhase.allCases.count)
    }
}
