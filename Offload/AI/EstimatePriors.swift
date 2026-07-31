import Foundation

/// What *your* recurring work actually takes, learned from your own finished tasks.
///
/// A general model guessing "review a lecture — 30 minutes" is guessing about lectures in general.
/// You've reviewed fourteen of them with a timer running, and they take you fifty-two minutes. Your
/// own history beats any prior on anything you do more than a few times, and it's the one source of
/// evidence a cloud model can never have.
///
/// This is deliberately lexical rather than embedding-based. The match has to be explicable on the
/// "what Offload has learned" screen — "because you've done 'review lecture' 14 times" is a
/// sentence; "because the cosine similarity was 0.83" is not. It's also fully testable without a
/// model being loaded.
enum EstimatePriors {

    /// Below this, a "typical" duration is one afternoon.
    static let minimumSample = 3
    /// How many priors to keep. Enough to cover the work you actually repeat, few enough that the
    /// learned screen stays readable and the profile stays small.
    static let limit = 40
    /// How much of two phrases' content must overlap to count as the same kind of work.
    static let matchThreshold = 0.6

    /// Words that carry no information about what a task *is*. Kept deliberately short — an
    /// aggressive list starts eating the domain nouns that make a phrase specific.
    static let stopWords: Set<String> = [
        "a", "an", "the", "my", "our", "this", "that", "these", "those",
        "and", "or", "but", "for", "with", "without", "to", "of", "in", "on", "at", "by", "from",
        "up", "out", "off", "over", "into", "about", "again", "some", "all", "any",
        "do", "does", "did", "doing", "done", "go", "get", "got", "make", "made",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "i", "me", "it", "its", "then", "than", "so", "just", "need", "needs", "needed"
    ]

    /// Reduce a title to the words that say what kind of work it is.
    ///
    /// Numbers go too, which matters more than it looks: "review lecture 4" and "review lecture 11"
    /// are the same *kind* of work with the same duration, and keeping the number would split one
    /// well-evidenced prior into a dozen useless ones. (This is the opposite of `ProjectMatcher`,
    /// where numbers are load-bearing — "Jury 3" and "Jury 4" are different projects. Same words,
    /// different question.)
    static func key(_ title: String) -> String {
        tokens(title).sorted().joined(separator: " ")
    }

    static func tokens(_ title: String) -> Set<String> {
        let cleaned = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
        return Set(cleaned
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) && Int($0) == nil })
    }

    /// Build priors from finished, timed work.
    ///
    /// Only tasks that actually ran a timer count, and the duration used is everything logged
    /// against the task across every sitting — so a four-hour job done in nine pomodoros over five
    /// days contributes its real four-and-a-half hours, not nine unrelated twenty-five-minute
    /// samples. Same reasoning as `TaskSessionLog.drift`.
    static func learn(tasks: [TaskItem], sessions: [TaskSession]) -> [EstimatePrior] {
        let byTask = Dictionary(grouping: sessions, by: \.taskId)
        var samples: [String: (label: String, minutes: [Double])] = [:]

        for task in tasks where task.status == "completed" && !task.deleted {
            guard let logged = byTask[task.id] else { continue }
            let spent = logged.reduce(0) { $0 + $1.actualMinutes }
            guard spent > 0 else { continue }
            let phrase = key(task.title)
            guard !phrase.isEmpty else { continue }
            samples[phrase, default: (label(for: task.title), [])].minutes.append(Double(spent))
        }

        return samples
            .filter { $0.value.minutes.count >= minimumSample }
            .map { phrase, value in
                EstimatePrior(key: phrase,
                              label: value.label,
                              medianMinutes: max(5, Int(median(value.minutes).rounded())),
                              sample: value.minutes.count)
            }
            .sorted { $0.sample > $1.sample }
            .prefix(limit)
            .map { $0 }
    }

    /// The prior that best describes a new title, or `nil` if this is new ground.
    ///
    /// Exact key first, then the best overlap above the threshold — so "review the cardio lecture"
    /// finds the "review lecture" prior, while "email the PI" finds nothing and is left alone.
    static func match(_ title: String, in priors: [EstimatePrior]) -> EstimatePrior? {
        let phrase = key(title)
        guard !phrase.isEmpty else { return nil }
        if let exact = priors.first(where: { $0.key == phrase }) { return exact }

        let wanted = tokens(title)
        guard !wanted.isEmpty else { return nil }
        var best: (prior: EstimatePrior, score: Double)?
        for prior in priors {
            let theirs = Set(prior.key.split(separator: " ").map(String.init))
            guard !theirs.isEmpty else { continue }
            let shared = Double(wanted.intersection(theirs).count)
            // Over the *smaller* side, so a short phrase fully contained in a longer one still
            // counts: "review lecture" inside "review the cardio lecture slides" is a match.
            let score = shared / Double(min(wanted.count, theirs.count))
            guard score >= matchThreshold else { continue }
            if best == nil || score > best!.score { best = (prior, score) }
        }
        return best?.prior
    }

    /// A better estimate for a new task, and why — or `nil` when history has nothing to say.
    ///
    /// Only overrides the model when the two genuinely disagree. Nudging 30 minutes to 32 is noise
    /// dressed up as intelligence, and it spends the user's trust for nothing.
    static func suggestion(for title: String, modelEstimate: Int?, priors: [EstimatePrior]) -> Suggestion? {
        guard let prior = match(title, in: priors) else { return nil }
        guard let modelEstimate, modelEstimate > 0 else {
            return Suggestion(minutes: prior.medianMinutes, prior: prior, replaced: nil)
        }
        let ratio = Double(prior.medianMinutes) / Double(modelEstimate)
        guard ratio >= 1.25 || ratio <= 0.8 else { return nil }
        return Suggestion(minutes: prior.medianMinutes, prior: prior, replaced: modelEstimate)
    }

    struct Suggestion: Equatable, Sendable {
        var minutes: Int
        var prior: EstimatePrior
        /// What the model had said, when it said anything.
        var replaced: Int?

        /// "You've done this 14 times — it takes you about 50 minutes."
        var reason: String {
            "You've done this \(prior.sample) times — it takes you about \(TimeFormat.duration(minutes))."
        }
    }

    /// A readable stand-in for a normalized key: the original title, trimmed and lowercased, so
    /// the learned screen shows "review lecture" rather than "lecture review" in sorted order.
    private static func label(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 40 ? trimmed : String(trimmed.prefix(39)) + "…"
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
