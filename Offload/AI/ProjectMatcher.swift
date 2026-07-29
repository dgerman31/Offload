import Foundation

/// Decides whether a project name the user just said is one they already have.
///
/// `findOrCreateProject` used to compare titles with `caseInsensitiveCompare`, so "Jury 3",
/// "jury3", "Jury-3" and "jury three" were four separate projects — captured over weeks, each
/// holding a slice of the same work. Spoken capture makes this the normal case, not the edge
/// one: dictation spells numbers out, drops hyphens, and hears "Redcap" as "red cap".
///
/// Three tiers, because the right response differs. `.exact` and `.close` are safe to act on
/// silently (with an undo); `.related` is a real guess and belongs in front of the user before
/// anything moves. Pure and embedder-injected, so every tier is unit-tested rather than trusted.
enum ProjectMatcher {

    enum Confidence: Sendable, Equatable {
        /// Identical once case, punctuation, and spelled-out numbers are normalized away.
        case exact
        /// A spelling slip or a longer phrasing of the same name — file it, say so, offer undo.
        case close
        /// Different words that may mean the same thing. Never acted on silently.
        case related
    }

    struct Match: Sendable, Equatable {
        let project: Project
        let confidence: Confidence
    }

    /// Cosine similarity at or above which two differently-worded names are the same project.
    /// Set high deliberately: `NLEmbedding` rates most short noun phrases as broadly similar, so
    /// a loose bar here would merge "Thesis" into "Dissertation defense" without asking.
    static let closeSimilarity = 0.90
    /// Below `closeSimilarity` but worth surfacing as a question.
    static let relatedSimilarity = 0.78

    /// The best existing project for `title`, or nil when it's genuinely new.
    ///
    /// `embedder` is optional so the fast, deterministic tiers can run without paying for a
    /// sentence embedding — callers inside a database write pass one only when they want the
    /// meaning-based tier.
    static func best(
        for title: String,
        among projects: [Project],
        embedder: (any TextEmbedding)? = nil
    ) -> Match? {
        let target = normalize(title)
        guard !target.isEmpty else { return nil }
        let live = projects.filter { !$0.deleted }
        guard !live.isEmpty else { return nil }

        // Tier 1: the same name, differently typed.
        if let exact = live.first(where: { normalize($0.title) == target }) {
            return Match(project: exact, confidence: .exact)
        }

        // Tier 2: a misspelling, or the same name inside a longer phrase. Both are decided on
        // characters and tokens alone — no model, no ambiguity.
        for project in live {
            let candidate = normalize(project.title)
            guard !candidate.isEmpty, numbersAgree(target, candidate) else { continue }
            if levenshtein(target, candidate) <= editTolerance(for: min(target.count, candidate.count)) {
                return Match(project: project, confidence: .close)
            }
            if isNameWithin(target, candidate) {
                return Match(project: project, confidence: .close)
            }
        }

        // Tier 3: different words, possibly the same thing. Only reached when the cheap tiers
        // found nothing, so the embedding cost is paid once per genuinely-new-looking name.
        guard let embedder, let targetVector = embedder.vector(for: title) else { return nil }
        var bestScore = 0.0
        var bestProject: Project?
        for project in live {
            // A name whose numbers disagree is a different thing however similar it reads —
            // "Jury 3" and "Jury 4" are the closest possible neighbours and the least mergeable.
            guard numbersAgree(target, normalize(project.title)),
                  let vector = embedder.vector(for: project.title) else { continue }
            let score = VectorMath.cosineSimilarity(targetVector, vector)
            if score > bestScore { bestScore = score; bestProject = project }
        }
        guard let bestProject else { return nil }
        if bestScore >= closeSimilarity { return Match(project: bestProject, confidence: .close) }
        if bestScore >= relatedSimilarity { return Match(project: bestProject, confidence: .related) }
        return nil
    }

    // MARK: Normalization

    /// Spoken numbers, so "jury three" and "Jury 3" land on the same string. Stops at twenty:
    /// past that, a project name with a spelled-out number is vanishingly rare, and every extra
    /// entry is another word that can't be part of a real name.
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
        "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16",
        "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20"
    ]

    /// Container nouns that describe the *kind* of thing rather than its name — "the Jury 3
    /// project" and "Jury 3" are one project, so a trailing one is dropped.
    private static let containerNouns: Set<String> = ["project", "list", "folder", "board"]

    /// A comparable form: lowercased, diacritics folded, punctuation dropped, spelled-out numbers
    /// digitized, a trailing container noun removed, whitespace collapsed.
    static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let separated = String(folded.map { ($0.isLetter || $0.isNumber) ? $0 : " " })
        var tokens = separated.split(separator: " ").map { numberWords[String($0)] ?? String($0) }
        // Only a *trailing* one: "Project Apollo" keeps its first word, which is part of the name.
        if tokens.count > 1, let last = tokens.last, containerNouns.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    // MARK: Tiers

    /// How many character edits still count as the same name. Short names get none — at four
    /// characters, one edit is the difference between "Labs" and "Lab5".
    static func editTolerance(for length: Int) -> Int {
        switch length {
        case ..<5:  return 0
        case ..<9:  return 1
        default:    return 2
        }
    }

    /// Do two normalized names carry the same numbers? A digit is the most load-bearing part of a
    /// project name and the cheapest thing for fuzzy matching to destroy: "Jury 3" and "Jury 4"
    /// differ by one character and are emphatically not the same project. Names with no digits
    /// at all agree trivially.
    static func numbersAgree(_ a: String, _ b: String) -> Bool {
        func digits(_ s: String) -> [String] {
            s.split(separator: " ").filter { $0.allSatisfy(\.isNumber) }.map(String.init)
        }
        return digits(a) == digits(b)
    }

    /// Is one name simply the other with extra words around it — "Jury 3" inside "Jury 3 trial
    /// prep"? Requires every word of the shorter name to appear in the longer one, and at least
    /// one of them to be substantial, so "Trip" doesn't swallow "Trip to Rome" on the strength
    /// of a preposition.
    static func isNameWithin(_ a: String, _ b: String) -> Bool {
        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return false }
        let (shorter, longer) = aTokens.count <= bTokens.count ? (aTokens, bTokens) : (bTokens, aTokens)
        guard shorter.isSubset(of: longer) else { return false }
        return shorter.contains { $0.count >= 3 || $0.allSatisfy(\.isNumber) }
    }

    /// Classic edit distance, two rows rather than a full matrix — project names are short and
    /// this runs once per existing project on every capture that names one.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
