import Testing
import Foundation
@testable import Offload

/// How long Anki actually takes.
///
/// The closed form here replaced `cards × 15s`, and the whole point is that it's much larger — so
/// these tests pin the *arithmetic*, including a check against an independent simulation of the
/// answer sequence. A plausible-looking wrong formula would quietly mis-plan every morning.
struct AnkiLoadTests {

    private let tolerance = 0.0005

    // MARK: Expected answers per card

    @Test("One success needed collapses to the plain geometric answer")
    func singleSuccess() {
        // Need one right answer, wrong 25% of the time → 1/0.75 answers.
        let expected = AnkiLoad.expectedAnswers(successesNeeded: 1, againRate: 0.25)
        #expect(abs(expected - 4.0 / 3.0) < tolerance)
    }

    @Test("Two in a row is far more than twice as expensive, because a lapse resets the streak")
    func twoInARow() {
        // The user's own numbers: new cards need 2 consecutive right answers, ~30% again.
        // Getting one wrong doesn't cost one answer, it costs the streak — so ~3.47, not ~2.3.
        let expected = AnkiLoad.expectedAnswers(successesNeeded: 2, againRate: 0.30)
        #expect(abs(expected - 3.4694) < 0.001)
        // Emphatically more than "two answers plus 30%".
        #expect(expected > 2 * 1.3)
    }

    @Test("The closed form matches a simulation of the real answer sequence")
    func matchesSimulation() {
        // Independent check of the derivation, not of the code: walk the actual streak state
        // machine with a fixed-seed generator and compare the mean.
        var rng = SeededRandom(seed: 20_260_729)
        let trials = 200_000
        let againRate = 0.30
        let needed = 2
        var total = 0
        for _ in 0..<trials {
            var streak = 0
            while streak < needed {
                total += 1
                if rng.nextUnit() < againRate { streak = 0 } else { streak += 1 }
            }
        }
        let simulated = Double(total) / Double(trials)
        let closedForm = AnkiLoad.expectedAnswers(successesNeeded: needed, againRate: againRate)
        #expect(abs(simulated - closedForm) < 0.02, "simulated \(simulated) vs \(closedForm)")
    }

    @Test("A perfect run costs exactly the number of steps")
    func neverWrong() {
        #expect(AnkiLoad.expectedAnswers(successesNeeded: 1, againRate: 0) == 1)
        #expect(AnkiLoad.expectedAnswers(successesNeeded: 2, againRate: 0) == 2)
        #expect(AnkiLoad.expectedAnswers(successesNeeded: 3, againRate: 0) == 3)
    }

    @Test("A hopeless again rate is clamped rather than diverging")
    func clampedRates() {
        // 100% again never graduates — an infinite expectation. Clamped, so the estimate stays a
        // (very large) number instead of infinity poisoning the schedule.
        let ceiling = AnkiLoad.expectedAnswers(successesNeeded: 2, againRate: 1.0)
        #expect(ceiling.isFinite)
        #expect(ceiling > 100)
        // Nonsense input can't produce a negative or sub-step estimate either.
        #expect(AnkiLoad.expectedAnswers(successesNeeded: 2, againRate: -1) == 2)
        #expect(AnkiLoad.expectedAnswers(successesNeeded: 0, againRate: 0.3) > 1)
    }

    @Test("A worse again rate always costs more")
    func monotonic() {
        let rates = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5]
        let values = rates.map { AnkiLoad.expectedAnswers(successesNeeded: 2, againRate: $0) }
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(b > a)
        }
    }

    // MARK: Minutes

    @Test("A real morning: 150 due plus 30 new is over an hour, not 45 minutes")
    func realisticMorning() {
        let minutes = AnkiLoad.minutes(due: 150, new: 30)
        #expect(minutes == 77)
        // What the old flat `cards × 15s` said, for contrast — the gap is the bug.
        #expect((180 * 15) / 60 == 45)
    }

    @Test("New cards dominate, which is why the Study tab read so low")
    func newCardsAreExpensive() {
        // 50 brand-new cards: the old maths said 12 minutes; it's really about three quarters
        // of an hour.
        #expect(AnkiLoad.minutesForNewCards(50) == 44)
        #expect((50 * 15) / 60 == 12)
    }

    @Test("Reviews and new cards are priced differently")
    func populationsDiffer() {
        let reviews = AnkiLoad.minutes(due: 100, new: 0)
        let news = AnkiLoad.minutes(due: 0, new: 100)
        #expect(news > reviews * 2)
    }

    @Test("Nothing due is zero minutes, not one")
    func emptyDay() {
        #expect(AnkiLoad.minutes(due: 0, new: 0) == 0)
        // Negative counts can't sneak in a negative estimate.
        #expect(AnkiLoad.minutes(due: -5, new: -5) == 0)
    }

    @Test("Minutes round up, so a session is never under-booked")
    func roundsUp() {
        // One new card is ~52 seconds — under a minute, but not zero.
        #expect(AnkiLoad.minutes(due: 0, new: 1) == 1)
        // Four reviews ≈ 80s → 2 minutes, not 1.
        #expect(AnkiLoad.minutes(due: 4, new: 0) == 2)
    }

    @Test("Seconds per answer scales the whole estimate")
    func secondsScale() {
        var fast = AnkiLoad.Settings.default
        fast.secondsPerAnswer = 8
        var slow = AnkiLoad.Settings.default
        slow.secondsPerAnswer = 20
        #expect(AnkiLoad.minutes(due: 100, new: 20, settings: slow)
                > AnkiLoad.minutes(due: 100, new: 20, settings: fast))
    }

    @Test("Learning steps drive the cost of new cards")
    func stepsMatter() {
        var oneStep = AnkiLoad.Settings.default
        oneStep.newSteps = 1
        var threeSteps = AnkiLoad.Settings.default
        threeSteps.newSteps = 3
        let cheap = AnkiLoad.minutesForNewCards(50, settings: oneStep)
        let dear = AnkiLoad.minutesForNewCards(50, settings: threeSteps)
        #expect(dear > cheap * 2)
    }

    // MARK: Presentation and the task

    @Test("The estimate explains itself")
    func explanation() {
        let text = AnkiLoad.explanation(due: 150, new: 30)
        #expect(text.contains("150 due"))
        #expect(text.contains("30 new"))
        #expect(text.contains("25%"))
        #expect(text.contains("30%"))
        #expect(text.contains("answers"))
        #expect(AnkiLoad.explanation(due: 0, new: 0) == "Nothing due.")
    }

    @Test("Durations read in hours once they pass one")
    func durationLabels() {
        #expect(AnkiLoad.durationLabel(43) == "43m")
        #expect(AnkiLoad.durationLabel(60) == "1h")
        #expect(AnkiLoad.durationLabel(76) == "1h 16m")
    }

    @Test("The morning task is pinned, so 'first' actually sticks")
    func taskIsAnchored() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let task = AnkiLoad.makeTask(due: 150, new: 30, at: start)
        #expect(task.title == AnkiLoad.taskTitle)
        #expect(task.effortMinutes == 77)
        #expect(task.category == StudyCatalog.category)
        // Pinned and anchored: `DayPlanner.candidates` skips it and `busyBlocks` treats it as a
        // constraint, which together are what stop the planner shuffling it out of first place.
        #expect(task.pinned)
        #expect(task.isAnchored)
        #expect(DueDate.parse(task.dueDate) == start)
    }

    @Test("The Study tab now prices catalog nodes as new cards")
    func studyCatalogUsesTheNewModel() {
        // A 64-card AnKing subtopic: 16 minutes under the old flat maths.
        #expect(StudyCatalog.ankiMinutes(forCards: 64) == AnkiLoad.minutesForNewCards(64))
        #expect(StudyCatalog.ankiMinutes(forCards: 64) > 45)
    }

    @Test("Settings round-trip, and an unset again rate doesn't read as zero")
    func storedSettings() {
        let defaults = UserDefaults(suiteName: "anki-load-tests-\(UUID().uuidString)")!
        // Nothing written yet: `double(forKey:)` returns 0, which is a *valid* again rate, so a
        // naive read would claim the user never gets anything wrong.
        let fresh = AnkiLoad.stored(defaults: defaults)
        #expect(fresh.reviewAgainRate == AnkiLoad.defaultReviewAgainRate)
        #expect(fresh.newAgainRate == AnkiLoad.defaultNewAgainRate)
        #expect(fresh.secondsPerAnswer == AnkiLoad.defaultSecondsPerAnswer)
        #expect(fresh.newSteps == AnkiLoad.defaultNewSteps)

        defaults.set(0.0, forKey: AnkiLoad.newAgainRateKey)
        #expect(AnkiLoad.stored(defaults: defaults).newAgainRate == 0)

        AnkiLoad.rememberCounts(due: 210, new: 25, defaults: defaults)
        let last = AnkiLoad.lastCounts(defaults: defaults)
        #expect(last.due == 210)
        #expect(last.new == 25)
    }
}

/// A tiny deterministic generator, so the simulation above is reproducible rather than flaky.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    /// xorshift64*
    private mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
