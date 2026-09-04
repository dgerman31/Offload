import Testing
import Foundation
@testable import Offload

/// The escalation ladder, and the copy that climbs it.
///
/// Worth testing properly rather than observing: checking these by hand means actually scrolling
/// Instagram for twenty minutes, which is a poor way to verify a tool built to stop you doing that.
struct ScrollGuardTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ScrollGuardTests-\(UUID().uuidString)")!
    }

    // MARK: The rungs

    @Test("The first minute is free")
    func graceIsSilent() {
        // The rule the whole feature depends on. A tool that punishes a thirty-second check is one
        // you switch off inside a week, and a switched-off tool helps nobody.
        #expect(ScrollGuard.beat(atElapsed: 0) == nil)
        #expect(ScrollGuard.beat(atElapsed: 59) == nil)
        #expect(ScrollGuard.beat(atElapsed: 119) == nil)
    }

    @Test("Each rung starts exactly where it says it does")
    func beatsMapToElapsedTime() {
        #expect(ScrollGuard.beat(atElapsed: 120) == .nudge)
        #expect(ScrollGuard.beat(atElapsed: 239) == .nudge)
        #expect(ScrollGuard.beat(atElapsed: 240) == .push)
        #expect(ScrollGuard.beat(atElapsed: 359) == .push)
        #expect(ScrollGuard.beat(atElapsed: 360) == .cost)
        #expect(ScrollGuard.beat(atElapsed: 599) == .cost)
        #expect(ScrollGuard.beat(atElapsed: 600) == .relentless)
        #expect(ScrollGuard.beat(atElapsed: 3600) == .relentless)
    }

    @Test("The ladder starts at two minutes and never repeats a time")
    func scheduleShape() {
        let schedule = ScrollGuard.schedule()
        #expect(schedule.first?.offset == 120)
        #expect(schedule.first?.beat == .nudge)
        // Strictly increasing: two notifications at the same instant would arrive as one.
        #expect(zip(schedule, schedule.dropFirst()).allSatisfy { $0.offset < $1.offset })
        #expect(schedule.allSatisfy { $0.offset >= ScrollGuard.firstNudgeSeconds })
    }

    @Test("It stays inside its share of the 64-notification budget")
    func scheduleRespectsTheCap() {
        // Task reminders already claim up to 40 of the 64 iOS allows. Blow this and the *task*
        // reminders start silently failing to schedule, which is a much worse bug than a missing
        // nudge.
        #expect(ScrollGuard.schedule().count <= ScrollGuard.maxNudges)
        #expect(ScrollGuard.schedule(limit: 5).count == 5)
    }

    @Test("The cadence tightens at ten minutes")
    func cadenceAccelerates() {
        let offsets = ScrollGuard.schedule().map(\.offset)
        // A gap in the steady stretch…
        let steady = zip(offsets, offsets.dropFirst()).first { $0.0 >= 240 && $0.1 <= 540 }
        #expect(steady.map { $0.1 - $0.0 } == ScrollGuard.steadyCadence)
        // …is longer than a gap once it turns relentless.
        let fast = zip(offsets, offsets.dropFirst()).first { $0.0 >= ScrollGuard.relentlessFromSeconds }
        #expect(fast.map { $0.1 - $0.0 } == ScrollGuard.relentlessCadence)
    }

    @Test("Every scheduled nudge knows which rung it's on")
    func everyNudgeHasABeat() {
        for nudge in ScrollGuard.schedule() {
            #expect(ScrollGuard.beat(atElapsed: nudge.offset) == nudge.beat)
        }
    }

    // MARK: Priced in work

    @Test("Minutes convert to cards, and never to a negative number")
    func costConversion() {
        #expect(ScrollGuard.minutes(600) == 10)
        #expect(ScrollGuard.cards(inSeconds: 600) == 75)
        #expect(ScrollGuard.cards(inSeconds: -5) == 0)
        #expect(ScrollGuard.minutes(-5) == 0)
    }

    // MARK: The off switch

    @Test("On unless it's been turned off")
    func defaultsToOn() {
        let defaults = freshDefaults()
        // Someone who set up the automation has already opted in; asking again inside the app is
        // how you ship a feature that never runs.
        #expect(ScrollGuard.isEnabled(defaults: defaults))
        ScrollGuard.setEnabled(false, defaults: defaults)
        #expect(!ScrollGuard.isEnabled(defaults: defaults))
    }

    @Test("A snooze expires on its own")
    func snoozeExpires() {
        let defaults = freshDefaults()
        ScrollGuard.snooze(.fifteenMinutes, now: at(14), calendar: calendar, defaults: defaults)
        #expect(ScrollGuard.isSnoozed(now: at(14, 10), defaults: defaults))
        #expect(!ScrollGuard.isSnoozed(now: at(14, 20), defaults: defaults))
    }

    @Test("\"Rest of today\" runs to 4am, not to midnight")
    func restOfDayCoversTheSmallHours() {
        // The hours either side of midnight are exactly when this is most needed and least
        // welcome. A quiet that silently re-armed at 00:01 would be a small betrayal.
        let expiry = ScrollGuard.Snooze.restOfDay.expiry(from: at(22), calendar: calendar)
        #expect(calendar.component(.hour, from: expiry) == 4)
        #expect(calendar.component(.day, from: expiry) == 21)
    }

    @Test("Armed means switched on and not snoozed")
    func armedNeedsBoth() {
        let defaults = freshDefaults()
        #expect(ScrollGuard.isArmed(now: at(14), defaults: defaults))

        ScrollGuard.snooze(.oneHour, now: at(14), calendar: calendar, defaults: defaults)
        #expect(!ScrollGuard.isArmed(now: at(14, 30), defaults: defaults))

        ScrollGuard.clearSnooze(defaults: defaults)
        #expect(ScrollGuard.isArmed(now: at(14, 30), defaults: defaults))

        ScrollGuard.setEnabled(false, defaults: defaults)
        #expect(!ScrollGuard.isArmed(now: at(14, 30), defaults: defaults))
    }

    // MARK: What counts

    @Test("A glance isn't scrolling")
    func graceIsNotRecorded() {
        #expect(ScrollGuard.recordableLength(3) == nil)
        #expect(ScrollGuard.recordableLength(59) == nil)
        #expect(ScrollGuard.recordableLength(60) == 60)
    }

    @Test("A session that outran its cap doesn't record hours of scrolling")
    func runawaySessionsAreCapped() {
        // The realistic failure: "Instagram → Is Closed" is a well-documented flaky trigger, so a
        // session can sit open until Offload is next launched — possibly hours later. Recording
        // that at face value would make the daily total, the one honest number here, a fiction.
        #expect(ScrollGuard.recordableLength(3 * 3600) == ScrollGuard.autoEndSeconds)
        #expect(ScrollGuard.recordableLength(600) == 600)
    }

    // MARK: Today's total

    @Test("The daily total accumulates and resets with the day")
    func dailyTotal() {
        let defaults = freshDefaults()
        #expect(ScrollGuard.todaySeconds(now: at(9), calendar: calendar, defaults: defaults) == 0)

        ScrollGuard.addToToday(300, now: at(9), calendar: calendar, defaults: defaults)
        ScrollGuard.addToToday(180, now: at(11), calendar: calendar, defaults: defaults)
        #expect(ScrollGuard.todaySeconds(now: at(11), calendar: calendar, defaults: defaults) == 480)

        // A day key, like every other once-a-day figure in the app, so it resets without anything
        // having to run at midnight.
        #expect(ScrollGuard.todaySeconds(now: at(9, day: 21), calendar: calendar, defaults: defaults) == 0)
    }
}

/// What it says while you're scrolling. The tone is the feature — a nudge that shames gets silenced
/// in two days, and one that reads as wallpaper stops working by Thursday.
struct ScrollLinesTests {

    private func context(task: String? = "Cardio Anki") -> ScrollLines.Context {
        ScrollLines.Context(minutes: 12, cards: 90, task: task)
    }

    @Test("No placeholder ever reaches the Lock Screen")
    func everyPlaceholderResolves() {
        // A notification that literally reads "{task} is waiting" is the most embarrassing possible
        // failure for a feature whose entire job is to be read.
        for beat in ScrollGuard.Beat.allCases {
            for index in 0..<20 {
                for task in [String?("Cardio Anki"), nil] {
                    let line = ScrollLines.line(for: beat, index: index,
                                                context: ScrollLines.Context(minutes: 12, cards: 90, task: task))
                    #expect(!line.title.contains("{"))
                    #expect(!line.body.contains("{"))
                    #expect(!line.title.isEmpty)
                    #expect(!line.body.isEmpty)
                }
            }
        }
    }

    @Test("Lines that need a task are skipped when there isn't one")
    func taskLinesNeedATask() {
        // Falling back to "what you were doing" everywhere would be worse than not trying: a nudge
        // that names the real thing lands, and a nudge that gestures at it vaguely is noise.
        for beat in ScrollGuard.Beat.allCases {
            for index in 0..<20 {
                let line = ScrollLines.line(for: beat, index: index,
                                            context: ScrollLines.Context(minutes: 12, cards: 90, task: nil))
                #expect(!line.body.contains("what you were doing"))
                #expect(!line.title.contains("what you were doing"))
            }
        }
    }

    @Test("A single session never repeats itself")
    func rotationIsDistinct() {
        let bank = ScrollLines.bank(for: .relentless).count
        let bodies = (0..<bank).map { ScrollLines.line(for: .relentless, index: $0, context: context()).body }
        #expect(Set(bodies).count == bank)
    }

    @Test("The rotation starts somewhere different each day")
    func daySeedRotates() {
        let monday = ScrollLines.line(for: .nudge, index: 0, context: context(), daySeed: 0)
        let tuesday = ScrollLines.line(for: .nudge, index: 0, context: context(), daySeed: 1)
        #expect(monday.body != tuesday.body)
    }

    @Test("The minutes and the cards are the real ones")
    func numbersAreSubstituted() {
        let filled = ScrollLines.fill("{mins} minutes ≈ {cards} cards, instead of {task}", context())
        #expect(filled == "12 minutes ≈ 90 cards, instead of Cardio Anki")
    }

    @Test("Every bank has lines that work without a task")
    func everyBankSurvivesWithoutATask() {
        // Otherwise the filter empties a bank and the fallback line — which exists only as a
        // backstop — becomes the entire experience of that rung.
        for beat in ScrollGuard.Beat.allCases {
            #expect(ScrollLines.bank(for: beat).contains { !$0.needsTask })
        }
    }
}
