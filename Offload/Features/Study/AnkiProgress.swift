import Foundation

/// One deck's day, as the Anki add-on last reported it.
///
/// The contract with `anki-addon/offload_anki` — every field comes from the tables Anki itself
/// schedules from, filtered to one deck tree. Counts only: nothing here is card content.
///
/// Decoded leniently rather than strictly. A snapshot that fails to decode because the add-on
/// gained a field is a progress bar that silently vanishes, and the add-on and the app are updated
/// independently — you'd have to reinstall one to fix the other.
struct AnkiSnapshot: Codable, Equatable, Sendable {
    var generatedAt: String
    var deck: String
    /// Epoch seconds of Anki's next rollover — its own day boundary, which isn't midnight.
    var dayCutoff: TimeInterval
    var today: Today
    var forecast: [ForecastDay]

    struct Today: Codable, Equatable, Sendable {
        /// Distinct review cards got through today. Not answers — a card you pressed Again on three
        /// times is one card, and counting answers would make the bar race ahead on a bad day.
        var reviewsDone: Int
        var newDone: Int
        var reviewsRemaining: Int
        var learningRemaining: Int
        var newRemaining: Int
        /// Every answer including repeats. Not what the bar is drawn from — it's what says how much
        /// today actually cost, which on a heavy Again day is a very different number.
        var answersDone: Int?
    }

    struct ForecastDay: Codable, Equatable, Sendable {
        /// Days from the snapshot's own "today". 1 is tomorrow.
        var day: Int
        var reviews: Int
    }

    // MARK: The bar

    /// Everything still waiting: reviews plus anything mid-learning.
    var dueRemaining: Int { max(0, today.reviewsRemaining + today.learningRemaining) }

    /// What today's due queue amounted to — what you've cleared plus what's left. Derived rather
    /// than reported because Anki has no stored notion of "today's total": the queue is simply
    /// whatever is due when you look, and cards you finish leave it.
    var dueTotal: Int { max(today.reviewsDone + dueRemaining, today.reviewsDone) }

    var isClear: Bool { dueRemaining == 0 }

    /// 0…1. A day with nothing due is complete, not empty — otherwise a rest day would read as 0%.
    var progress: Double {
        guard dueTotal > 0 else { return 1 }
        return min(1, max(0, Double(today.reviewsDone) / Double(dueTotal)))
    }

    /// Roughly how long the rest of the queue will take, using the app's own answer-based model —
    /// which accounts for again-rates and learning steps rather than pretending every card is one
    /// press. See `AnkiLoad`.
    func minutesLeft(settings: AnkiLoad.Settings = AnkiLoad.stored()) -> Int {
        AnkiLoad.minutes(due: dueRemaining, new: today.newRemaining, settings: settings)
    }

    // MARK: Freshness
    //
    // Both of these matter because the add-on runs on a Mac that may be asleep, and a stale number
    // presented as a live one is worse than no number at all.

    var generated: Date? { DueDate.parse(generatedAt) }

    /// When Anki's day rolls over and these figures stop meaning anything.
    var expiry: Date { Date(timeIntervalSince1970: dayCutoff) }

    /// Past Anki's rollover — the numbers describe a day that has ended.
    func isExpired(now: Date = Date()) -> Bool { now >= expiry }

    /// Old enough to say so. Not an error: the Mac being asleep is the normal case, and the figures
    /// are still the last true thing we know.
    func isStale(now: Date = Date(), after minutes: Int = 45) -> Bool {
        guard let generated else { return true }
        return now.timeIntervalSince(generated) > Double(minutes) * 60
    }

    /// "Updated 12 min ago" — shown whenever it isn't essentially live, so a number that's an hour
    /// behind can never be mistaken for one that isn't.
    func freshnessLabel(now: Date = Date()) -> String? {
        guard let generated else { return "Never updated" }
        let seconds = now.timeIntervalSince(generated)
        guard seconds > 120 else { return nil }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Updated \(Int(seconds / 3600))h ago" }
        return "Updated \(Int(seconds / 86_400))d ago"
    }
}

/// The reading of a forecast — what's coming, and whether it's worth saying anything about.
enum AnkiForecast {

    /// The heaviest day in the window, if there is one.
    static func peak(_ forecast: [AnkiSnapshot.ForecastDay]) -> AnkiSnapshot.ForecastDay? {
        forecast.filter { $0.day >= 1 }.max { $0.reviews < $1.reviews }
    }

    static func reviews(on day: Int, in forecast: [AnkiSnapshot.ForecastDay]) -> Int {
        forecast.first { $0.day == day }?.reviews ?? 0
    }

    /// What a normal day looks like, with one day left out of its own comparison.
    ///
    /// Leaving it out matters: a 400-card day averaged in alongside three 100-card days drags the
    /// baseline to 175 and the spike stops looking like one. The thing we're measuring can't be
    /// part of what we measure it against.
    static func baseline(_ forecast: [AnkiSnapshot.ForecastDay], excluding day: Int? = nil) -> Double {
        let rest = forecast.filter { $0.day >= 1 && $0.day != day }
        guard !rest.isEmpty else { return 0 }
        return Double(rest.reduce(0) { $0 + $1.reviews }) / Double(rest.count)
    }

    /// How much bigger than normal a day has to be before it's worth mentioning, and the floor
    /// below which no multiple is interesting.
    static let spikeMultiple = 1.5
    static let minimumSpike = 120

    /// The one line worth saying about what's coming, or nil — which it usually is.
    ///
    /// Deliberately silent most days. A forecast that comments every morning becomes weather; one
    /// that speaks only when a day is genuinely unlike the others gets read.
    static func warning(_ forecast: [AnkiSnapshot.ForecastDay]) -> String? {
        guard let peak = peak(forecast), peak.reviews >= minimumSpike else { return nil }
        let normal = baseline(forecast, excluding: peak.day)
        guard normal > 0, Double(peak.reviews) >= normal * spikeMultiple else { return nil }
        let when: String
        switch peak.day {
        case 1:  when = "Tomorrow"
        case 2:  when = "The day after tomorrow"
        default: when = "In \(peak.day) days"
        }
        return "\(when): \(peak.reviews) reviews — about \(Int((Double(peak.reviews) / max(normal, 1)) * 100 - 100))% above your normal day."
    }
}
