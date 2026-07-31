import Foundation

/// One estimate learned from your own finished work.
struct EstimatePrior: Codable, Equatable, Sendable {
    /// The normalized phrase this applies to — content words only, so "review the cardio lecture"
    /// and "reviewing cardio lectures" land on the same key.
    var key: String
    /// A readable version of the phrase, for the "what I've learned" screen.
    var label: String
    var medianMinutes: Int
    var sample: Int
}

/// Everything the app has worked out about how you actually operate, in one place.
///
/// This exists because the alternative was already happening: `TaskSessionLog` measured drift and
/// nothing read it, `HabitLearning` derived a peak hour and only ever printed it on a stats screen,
/// and the correction ledger fed the extractor but nothing else. Each new piece of learning was
/// inventing its own storage, its own idea of "enough evidence", and its own way of going unused.
///
/// Stored as JSON in `UserDefaults` rather than a table, deliberately: the planner is pure,
/// synchronous, and called from inside view bodies, so it needs a read that can't be `await`ed.
/// Same reasoning as `ProtectedTime`. It's derived data — losing it costs one night's recompute.
///
/// **Nothing here is applied until it has enough evidence.** Every reader checks its own sample
/// gate, because a profile built from four sessions is a rumour, not a model.
struct LearnedProfile: Codable, Equatable, Sendable {

    /// When the nightly pass last rebuilt this.
    var updatedAt: Date?

    // MARK: How long work really takes

    /// Actual-over-estimated, across all finished tasks. 1.4 means work runs about 40% long.
    var driftOverall: Double?
    /// The same, per category — Work and Personal drift differently.
    var driftByCategory: [String: Double] = [:]
    /// How many finished, timed tasks the drift figures are built from.
    var finishedTaskSample = 0

    // MARK: When you actually work well

    /// 0–23 → how well that hour goes for you, normalized 0...1. See `EnergyCurve`.
    var hourScores: [Int: Double] = [:]
    /// The best few hours, in clock order. Empty until there's enough history.
    var peakHours: [Int] = []
    var sessionSample = 0

    // MARK: What things tend to take, and what you call them

    var estimatePriors: [EstimatePrior] = []
    /// Words you use that a general model would mangle — REDCap, OSCE, shelf.
    var glossary: [String] = []

    // MARK: Gates

    /// Below this many finished tasks, a drift multiplier is one bad week rather than a pattern.
    static let minimumDriftSample = 5
    /// Drift is never applied beyond this, in either direction. A learned model that can triple a
    /// block is a learned model that can ruin a day; the honest response to a 3× ratio is to fix
    /// the estimate, not to silently plan around it.
    static let maximumStretch = 2.0
    static let minimumStretch = 0.6
    /// Corrections under this size aren't worth mentioning, let alone acting on.
    static let meaningfulChange = 0.1

    nonisolated static let storageKey = "offload.learning.profile"

    // MARK: Reading

    /// The drift multiplier that applies to a task: its category's if that category has its own
    /// history, otherwise the overall figure.
    func drift(for category: String?) -> Double? {
        guard finishedTaskSample >= Self.minimumDriftSample else { return nil }
        if let category, let specific = driftByCategory[category] { return specific }
        return driftOverall
    }

    /// What the planner should actually reserve for a task, and why.
    ///
    /// Returns `nil` when nothing was learned or the correction is too small to bother with — so
    /// callers can distinguish "no adjustment" from "adjusted by zero", and only explain themselves
    /// when there's something to explain.
    func adjustment(for task: TaskItem) -> Adjustment? {
        // A task corrected at capture already carries the multiplier in its stored estimate.
        // Applying it again here would compound it — a 40% bias would reserve 96 minutes for an
        // hour of work, and by the third pass the day would be fiction.
        guard LearnedEstimate.decode(task.metadata) == nil else { return nil }
        let base = task.effortMinutes ?? EnergyBatch.defaultEffort
        return adjustment(minutes: base, category: task.category)
    }

    func adjustment(minutes base: Int, category: String?) -> Adjustment? {
        guard base > 0, let multiplier = drift(for: category) else { return nil }
        guard abs(multiplier - 1) >= Self.meaningfulChange else { return nil }
        let clamped = min(Self.maximumStretch, max(Self.minimumStretch, multiplier))
        // To the nearest five minutes: the planner schedules on quarter-hours and "77 minutes"
        // reads as a measurement rather than a plan.
        let adjusted = max(5, Int((Double(base) * clamped / 5).rounded() * 5))
        guard adjusted != base else { return nil }
        return Adjustment(base: base, adjusted: adjusted, multiplier: clamped, category: category)
    }

    /// Minutes to reserve for a task — the adjusted figure when there's evidence, the estimate
    /// as given otherwise.
    func plannedMinutes(for task: TaskItem) -> Int {
        adjustment(for: task)?.adjusted ?? task.effortMinutes ?? EnergyBatch.defaultEffort
    }

    /// The learned peak window, if there's enough history to trust it — otherwise `nil`, and the
    /// caller falls back to whatever the user declared.
    var learnedPeakHours: [Int]? {
        peakHours.isEmpty ? nil : peakHours
    }

    /// The best-matching learned estimate for a phrase, or `nil` if this is new ground.
    func prior(matching title: String) -> EstimatePrior? {
        EstimatePriors.match(title, in: estimatePriors)
    }

    /// An adjustment, and the sentence that justifies it.
    ///
    /// Every learned change carries its reason, because a block that quietly became 85 minutes is
    /// indistinguishable from a bug. The user can always see what changed, why, and put it back.
    struct Adjustment: Equatable, Sendable {
        var base: Int
        var adjusted: Int
        var multiplier: Double
        var category: String?

        var isStretch: Bool { adjusted > base }
        var percent: Int { Int((abs(multiplier - 1) * 100).rounded()) }

        /// "Your Work runs about 40% long." — the whole justification, in one line.
        var reason: String {
            let what = category.map { "Your \($0)" } ?? "Your work"
            return isStretch
                ? "\(what) runs about \(percent)% long."
                : "\(what) usually finishes about \(percent)% early."
        }

        /// "85 min, not 60" — for a compact badge.
        var shortLabel: String { "\(adjusted)m, not \(base)m" }
    }

    // MARK: Storage

    static func stored(defaults: UserDefaults = .standard) -> LearnedProfile {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(LearnedProfile.self, from: data)
        else { return LearnedProfile() }
        return decoded
    }

    static func save(_ profile: LearnedProfile, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Throw away everything learned and start again — the escape hatch that makes the rest of
    /// this safe to turn on. Offered on the "what Offload has learned" screen.
    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// A note left on a task whose estimate the app changed, so the change can be explained and undone.
///
/// This is the whole difference between learning and meddling. A block that silently became 85
/// minutes is indistinguishable from a bug; one that says *85 minutes, not 60 — your Work runs 40%
/// long* — with a button to put it back — is the app showing its working. The original is stored
/// because "undo" has to mean the number the user or the model actually chose, not an inverse
/// calculation that lands two minutes off.
///
/// Rides in `TaskItem.metadata`, which is a flat `[String: String]` JSON object. Unknown keys are
/// preserved on write, so this can never clobber the routine marker that also lives there.
enum LearnedEstimate {
    static let originalKey = "estimateBefore"
    static let reasonKey = "estimateReason"

    struct Note: Equatable, Sendable {
        /// What it was before, when there was a "before" to go back to. `nil` when the model gave
        /// no estimate at all and this figure is the only one anyone has ever had — there's still
        /// something to explain, but nothing to revert to.
        var original: Int?
        var reason: String
    }

    static func decode(_ metadata: String?) -> Note? {
        let dict = dictionary(metadata)
        guard let reason = dict[reasonKey] else { return nil }
        return Note(original: dict[originalKey].flatMap(Int.init), reason: reason)
    }

    /// Add the note to whatever metadata a task already carries.
    static func encode(original: Int?, reason: String, into metadata: String? = nil) -> String? {
        var dict = dictionary(metadata)
        if let original { dict[originalKey] = String(original) } else { dict[originalKey] = nil }
        dict[reasonKey] = reason
        return string(from: dict)
    }

    /// Strip the note — what "put it back" writes, so a reverted task looks untouched rather than
    /// carrying a stale explanation of a change that's no longer there.
    static func removing(from metadata: String?) -> String? {
        var dict = dictionary(metadata)
        guard dict[originalKey] != nil || dict[reasonKey] != nil else { return metadata }
        dict[originalKey] = nil
        dict[reasonKey] = nil
        return dict.isEmpty ? nil : string(from: dict)
    }

    private static func dictionary(_ metadata: String?) -> [String: String] {
        guard let metadata, let data = metadata.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func string(from dict: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
