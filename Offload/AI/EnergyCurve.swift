import Foundation

/// When you actually work well, learned rather than declared.
///
/// `EnergyProfile` asks you to pick morning, afternoon, or night once and never revisits it. The
/// focus timer, meanwhile, has been recording every sitting you've ever done: what hour it started
/// and how long you actually stayed with it. That's the answer to the same question, measured.
///
/// ### Why this measures quality, not volume
///
/// The obvious version — count focused minutes per hour and call the biggest one your peak — is a
/// feedback loop, not a measurement. The planner schedules your mornings, so you work mornings, so
/// it learns you're a morning person, so it schedules your mornings. It would confirm whatever it
/// started with and never discover it was wrong.
///
/// So the score is **median minutes per sitting started in that hour**. An hour where you start
/// four sessions and bail after six minutes each scores badly no matter how often you're scheduled
/// into it; an hour where you start once and stay ninety minutes scores well despite the low
/// volume. That's exposure-normalized: it asks how an hour goes *once you're in it*, which is the
/// thing the schedule can't manufacture.
enum EnergyCurve {

    /// Below this many sittings in total, there's no curve — just a handful of afternoons.
    static let minimumSessions = 12
    /// An hour needs its own repeated evidence before it's scored at all. One brilliant 7am is not
    /// a morning habit.
    static let minimumSessionsPerHour = 3
    /// How many hours make up "your peak". Four is roughly a working block, and small enough that
    /// calling them peak still means something.
    static let peakHourCount = 4
    /// A peak hour has to clear this share of your best hour.
    static let peakThreshold = 0.6
    /// …*and* stand this far clear of your typical hour. Without the second bar, a day where every
    /// hour is equally good would report four arbitrary hours as your peak, which is worse than
    /// reporting none: it's a confident answer to a question the data can't settle.
    static let peakMargin = 0.15
    /// Fewer scored hours than this and there's nothing to compare — an hour can't be your best
    /// when it's very nearly your only.
    static let minimumScoredHours = 3

    struct Curve: Equatable, Sendable {
        /// 0–23 → 0...1, only for hours with enough evidence.
        var scores: [Int: Double] = [:]
        /// Your best hours, in clock order.
        var peak: [Int] = []
        var sample = 0

        var isConfident: Bool { !peak.isEmpty }
    }

    /// Derive the curve from focus history. Pure, so the rule is testable without a database.
    static func learn(_ sessions: [TaskSession], calendar: Calendar = .current) -> Curve {
        var curve = Curve()
        guard sessions.count >= minimumSessions else { return curve }

        var byHour: [Int: [Double]] = [:]
        for session in sessions {
            guard session.actualMinutes > 0, let started = DueDate.parse(session.startedAt) else { continue }
            byHour[calendar.component(.hour, from: started), default: []].append(Double(session.actualMinutes))
        }
        curve.sample = byHour.values.reduce(0) { $0 + $1.count }
        guard curve.sample >= minimumSessions else { return curve }

        // Median rather than mean, for the same reason drift uses one: a single timer left running
        // through lunch would otherwise crown whatever hour it started in.
        var medians: [Int: Double] = [:]
        for (hour, values) in byHour where values.count >= minimumSessionsPerHour {
            medians[hour] = median(values)
        }
        guard let best = medians.values.max(), best > 0 else { return curve }

        curve.scores = medians.mapValues { $0 / best }
        guard curve.scores.count >= minimumScoredHours else { return curve }

        // Two bars, not one: a share of your best hour, *and* a clear margin over your typical
        // hour. The second is what makes a flat day produce no peak instead of an arbitrary one.
        let bar = max(peakThreshold, median(Array(curve.scores.values)) + peakMargin)
        curve.peak = curve.scores
            .filter { $0.value >= bar }
            .sorted { $0.value > $1.value }
            .prefix(peakHourCount)
            .map(\.key)
            .sorted()
        return curve
    }

    /// How the curve reads on the "what Offload has learned" screen.
    static func describe(_ curve: Curve, calendar: Calendar = .current) -> String? {
        guard curve.isConfident, let first = curve.peak.first, let last = curve.peak.last else { return nil }
        // Contiguous hours read as a window; scattered ones have to be listed.
        let contiguous = curve.peak == Array(first...last)
        if contiguous {
            return "You do your best work between \(hourLabel(first)) and \(hourLabel(last + 1))."
        }
        return "Your best hours are " + curve.peak.map(hourLabel).joined(separator: ", ") + "."
    }

    static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 0:  return "12am"
        case 12: return "12pm"
        case 1..<12: return "\(h)am"
        default: return "\(h - 12)pm"
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
