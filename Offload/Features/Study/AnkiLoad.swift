import Foundation

/// How long today's Anki actually takes.
///
/// The old estimate was `cards × 15s`, which is the time it would take if you got everything
/// right first try. You don't — and in Anki, getting one wrong doesn't cost you 15 seconds, it
/// costs you *the whole card again*, because a lapse sends it back through its learning steps.
/// The gap isn't a rounding error: 50 new cards was budgeted at 12 minutes and genuinely takes
/// about 43.
///
/// Two card populations, because they behave differently:
///
/// - **Reviews** (today's due pile). A lapse drops the card into relearning, and one correct
///   answer graduates it back. So one success is needed, from whatever state you're in.
/// - **New cards.** Anki's default learning steps need **two consecutive** correct answers, and
///   answering "Again" resets the streak — so a wrong answer means two *more* right ones, not one.
///   That reset is what makes new cards so much more expensive than their count suggests.
///
/// Everything here is pure and closed-form, and the closed form was checked against a Monte Carlo
/// simulation of the actual answer sequence (3.4694 predicted vs 3.4719 simulated over 400k
/// cards at the defaults below) — worth doing, because a plausible-looking wrong formula here
/// would quietly mis-plan every morning.
enum AnkiLoad {

    // MARK: Settings

    static let secondsPerAnswerKey = "offload.anki.secondsPerAnswer"
    static let reviewAgainRateKey = "offload.anki.reviewAgainRate"
    static let newAgainRateKey = "offload.anki.newAgainRate"
    static let newStepsKey = "offload.anki.newSteps"
    /// Last counts entered, so the morning prompt starts from yesterday's numbers rather than zero.
    static let lastDueKey = "offload.anki.lastDue"
    static let lastNewKey = "offload.anki.lastNew"

    /// Seconds per *answer*, not per card — the distinction is the whole point. A card you fail
    /// twice costs three of these.
    static let defaultSecondsPerAnswer = 15
    static let defaultReviewAgainRate = 0.25
    static let defaultNewAgainRate = 0.30
    /// Consecutive correct answers a new card needs before it leaves the learning queue —
    /// Anki's default `1m 10m` steps, so two.
    static let defaultNewSteps = 2
    /// A lapsed review needs one correct answer to graduate out of relearning (`10m`).
    static let reviewSteps = 1

    struct Settings: Equatable, Sendable {
        var secondsPerAnswer: Int = defaultSecondsPerAnswer
        var reviewAgainRate: Double = defaultReviewAgainRate
        var newAgainRate: Double = defaultNewAgainRate
        var newSteps: Int = defaultNewSteps

        static let `default` = Settings()
    }

    nonisolated static func stored(defaults: UserDefaults = .standard) -> Settings {
        var settings = Settings()
        let seconds = defaults.integer(forKey: secondsPerAnswerKey)
        if seconds > 0 { settings.secondsPerAnswer = seconds }
        let steps = defaults.integer(forKey: newStepsKey)
        if steps > 0 { settings.newSteps = steps }
        // `double(forKey:)` returns 0 for an unset key, which is a legitimate again rate — so an
        // unset rate has to fall back rather than read as "you never get anything wrong".
        if defaults.object(forKey: reviewAgainRateKey) != nil {
            settings.reviewAgainRate = defaults.double(forKey: reviewAgainRateKey)
        }
        if defaults.object(forKey: newAgainRateKey) != nil {
            settings.newAgainRate = defaults.double(forKey: newAgainRateKey)
        }
        return settings
    }

    // MARK: The maths

    /// Expected number of answers to finish one card that needs `successesNeeded` **consecutive**
    /// correct answers, where any answer is "Again" with probability `againRate`.
    ///
    /// Closed form of the obvious Markov chain: with `q = 1 - p` and `k` successes needed,
    /// `E = (q^-k - 1) / p`. Reads oddly but it's exact, and it collapses to the two cases you'd
    /// check by hand — `k = 1` gives `1/q` (the plain geometric answer), and `p → 0` gives `k`.
    static func expectedAnswers(successesNeeded: Int, againRate: Double) -> Double {
        let k = max(1, successesNeeded)
        // Clamped rather than trusted: a rate of 1.0 means "never graduates", which is an
        // infinite expectation, and 0.99 is already an absurd enough estimate to be obvious.
        let p = min(0.99, max(0, againRate))
        guard p > 0 else { return Double(k) }
        let q = 1 - p
        return (pow(q, -Double(k)) - 1) / p
    }

    /// Answers expected for `due` reviews and `new` new cards together.
    static func expectedAnswers(due: Int, new: Int, settings: Settings = .default) -> Double {
        let reviews = Double(max(0, due))
            * expectedAnswers(successesNeeded: reviewSteps, againRate: settings.reviewAgainRate)
        let learning = Double(max(0, new))
            * expectedAnswers(successesNeeded: settings.newSteps, againRate: settings.newAgainRate)
        return reviews + learning
    }

    /// Minutes for today's session, rounded up — a session is never usefully described as taking
    /// zero minutes, and rounding down would systematically under-book the very thing this exists
    /// to stop under-booking.
    static func minutes(due: Int, new: Int, settings: Settings = .default) -> Int {
        guard due > 0 || new > 0 else { return 0 }
        let seconds = expectedAnswers(due: due, new: new, settings: settings)
            * Double(max(1, settings.secondsPerAnswer))
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    /// Minutes for a pile of cards that are all **new** — what the Study tab's catalog nodes are.
    /// Every AnKing card under a subtopic is one you haven't seen, so the expensive model is the
    /// correct one for them, and using the cheap one is what made those estimates read low.
    static func minutesForNewCards(_ count: Int, settings: Settings = .default) -> Int {
        minutes(due: 0, new: count, settings: settings)
    }

    /// "1h 16m" / "43m".
    static func durationLabel(_ minutes: Int) -> String { TimeFormat.duration(minutes) }

    /// A one-line explanation of where the number came from, so a surprisingly large estimate
    /// reads as arithmetic rather than as the app being wrong.
    static func explanation(due: Int, new: Int, settings: Settings = .default) -> String {
        var parts: [String] = []
        if due > 0 {
            let rate = Int((settings.reviewAgainRate * 100).rounded())
            parts.append("\(due) due at ~\(rate)% again")
        }
        if new > 0 {
            let rate = Int((settings.newAgainRate * 100).rounded())
            parts.append("\(new) new needing \(settings.newSteps) in a row at ~\(rate)% again")
        }
        guard !parts.isEmpty else { return "Nothing due." }
        let answers = Int(expectedAnswers(due: due, new: new, settings: settings).rounded())
        return parts.joined(separator: ", ") + " ≈ \(answers) answers"
    }

    // MARK: Today's task

    static let taskTitle = "Anki: today's cards"

    /// The morning's Anki task. Pinned, because the user's rule is that it comes first and a soft
    /// time would let the planner reflow it behind something else.
    static func makeTask(due: Int, new: Int, at start: Date, settings: Settings = .default) -> TaskItem {
        TaskItem(
            title: taskTitle,
            descriptionText: explanation(due: due, new: new, settings: settings),
            category: StudyCatalog.category,
            priority: "high",
            dueDate: DueDate.canonicalString(from: start),
            dueDateConfidence: 1.0,
            effortMinutes: minutes(due: due, new: new, settings: settings),
            pinned: true
        )
    }

    nonisolated static func rememberCounts(due: Int, new: Int, defaults: UserDefaults = .standard) {
        defaults.set(due, forKey: lastDueKey)
        defaults.set(new, forKey: lastNewKey)
    }

    nonisolated static func lastCounts(defaults: UserDefaults = .standard) -> (due: Int, new: Int) {
        (defaults.integer(forKey: lastDueKey), defaults.integer(forKey: lastNewKey))
    }
}
