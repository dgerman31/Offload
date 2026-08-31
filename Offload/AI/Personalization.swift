import Foundation
import GRDB

/// Turns the correction ledger into few-shot guidance for the extractor.
///
/// Every time you fixed the AI's category or priority, that was recorded — and then never
/// used. This closes the loop: your past corrections become worked examples in the prompt, so
/// the model learns *your* filing habits instead of repeating the same mistake forever.
///
/// This is the kind of thing only an on-device app can do casually: the examples are your real
/// task titles, and they never leave the phone.
enum Personalization {

    /// One thing the user taught the model by overriding it.
    struct Lesson: Equatable, Sendable {
        var field: String          // "category" | "priority" | ...
        var taskTitle: String
        var from: String           // what the model said
        var to: String             // what the user chose
    }

    /// Fields worth teaching. Title edits are too freeform to generalise from, and due-date
    /// corrections are usually one-offs rather than a pattern.
    ///
    /// `effortMinutes` earns its place because it's the correction this user makes most and the
    /// one the model is worst at: it has no idea that entering a semester of REDCap data is a
    /// four-hour job rather than a thirty-minute one, and no amount of general knowledge will
    /// tell it. Being shown "they changed 30 to 240 on this" is the only way it finds out.
    /// `kind` is the newest and the most valuable of them: it's the correction that says "that was
    /// an idea, not a to-do", and getting it wrong is the mistake this user actually noticed.
    static let learnableFields: Set<String> = ["category", "priority", "effortMinutes", "kind"]

    /// Words too common to say anything about what a capture is about. Kept deliberately short —
    /// this is a relevance nudge, not a search engine.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "have", "has", "had", "was", "were", "are",
        "you", "your", "need", "needs", "should", "would", "could", "want", "wants", "get", "got",
        "make", "made", "into", "from", "about", "just", "some", "any", "all", "out", "off", "not",
        "but", "then", "than", "them", "they", "there", "here", "what", "when", "who", "how"
    ]

    /// Content words in a piece of text: lowercased, three letters or more, minus the stopwords.
    static func tokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// How much of a past task's title is echoed in what's just been captured, 0…1.
    ///
    /// The point is to put the *relevant* corrections in front of the model rather than merely the
    /// newest. Six lessons about grocery categories teach nothing about a capture on renal
    /// physiology, and a prompt has a finite budget for examples — spending it on the six nearest
    /// ones is the single cheapest quality gain available, and it costs no network call, which an
    /// embedding lookup in the capture hot path would.
    static func relevance(of title: String, to transcript: String) -> Double {
        let titleTokens = tokens(title)
        guard !titleTokens.isEmpty else { return 0 }
        let shared = titleTokens.intersection(tokens(transcript))
        return Double(shared.count) / Double(titleTokens.count)
    }

    /// Build lessons from raw corrections, newest first. Keeps only the most recent correction
    /// per task+field (so repeatedly editing one task doesn't drown out everything else), drops
    /// no-op corrections, and de-duplicates identical lessons.
    ///
    /// When `matching` is supplied, the surviving lessons are re-ranked so the ones that actually
    /// resemble what was just said come first, with recency breaking ties. Pass nil to keep the
    /// pure newest-first behaviour.
    static func lessons(
        corrections: [Correction],
        tasks: [TaskItem],
        limit: Int = 6,
        matching transcript: String? = nil
    ) -> [Lesson] {
        let titlesById = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        // Newest first — corrections carry ISO timestamps, which sort lexicographically.
        let ordered = corrections.sorted { $0.createdAt > $1.createdAt }

        var seenTaskField = Set<String>()
        var seenLesson = Set<String>()
        var result: [Lesson] = []

        for correction in ordered {
            guard learnableFields.contains(correction.field),
                  let from = correction.modelValue?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty,
                  let to = correction.userValue?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty,
                  from.caseInsensitiveCompare(to) != .orderedSame,
                  let taskId = correction.taskId,
                  let title = titlesById[taskId], !title.isEmpty
            else { continue }

            let taskFieldKey = "\(taskId)|\(correction.field)"
            guard seenTaskField.insert(taskFieldKey).inserted else { continue }

            let lessonKey = "\(correction.field)|\(title.lowercased())|\(to.lowercased())"
            guard seenLesson.insert(lessonKey).inserted else { continue }

            result.append(Lesson(field: correction.field, taskTitle: title, from: from, to: to))
            // With a transcript to match against, every candidate has to be scored before any is
            // discarded — cutting at `limit` here would keep the six newest and then rank those,
            // which is not the same thing at all.
            if transcript == nil, result.count >= limit { break }
        }

        guard let transcript, !transcript.isEmpty else { return Array(result.prefix(limit)) }

        // Decorate–sort–undecorate on (relevance desc, original position asc). The index tiebreak
        // is explicit because `sort` isn't guaranteed stable, and the original order is recency.
        let ranked = result.enumerated()
            .map { (index: $0.offset, lesson: $0.element, score: relevance(of: $0.element.taskTitle, to: transcript)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
        return ranked.prefix(limit).map(\.lesson)
    }

    /// Read the ledger and build the fragment in one call — shared by both the on-device and
    /// cloud extraction paths so they personalise identically.
    ///
    /// Two kinds of learning end up here. **Corrections** teach judgement: where this person files
    /// things, what they consider urgent. **Vocabulary** teaches language: the words they use that
    /// a general model would mangle. They're combined at this seam so both extraction paths get
    /// both, without either call site knowing there are two.
    static func fragment(
        db: AppDatabase,
        profile: LearnedProfile = .stored(),
        matching transcript: String? = nil,
        limit: Int = 6
    ) async -> String? {
        // Read a wider window than we'll use: with a transcript to rank against, the best six
        // examples are rarely the six most recent, and they can't be found in rows we never read.
        let window = max(60, limit * 6)
        let data = try? await db.dbQueue.read { database in
            (try Correction.order(Column("created_at").desc).limit(window).fetchAll(database),
             try TaskItem.filter(Column("deleted") == false).fetchAll(database))
        }
        let corrections = data?.0 ?? []
        let tasks = data?.1 ?? []
        let parts = [
            Glossary.promptFragment(profile.glossary),
            promptFragment(lessons(corrections: corrections, tasks: tasks, limit: limit, matching: transcript))
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Render lessons as an instruction block. Returns nil when there's nothing learned yet,
    /// so a new user's prompt stays clean.
    static func promptFragment(_ lessons: [Lesson]) -> String? {
        guard !lessons.isEmpty else { return nil }

        let lines = lessons.map { lesson -> String in
            switch lesson.field {
            case "category":
                return "- \"\(lesson.taskTitle)\" belongs in \(lesson.to), not \(lesson.from)."
            case "priority":
                return "- \"\(lesson.taskTitle)\" is \(lesson.to) priority, not \(lesson.from)."
            case "kind":
                // Phrased as what the thing *is*, not as a column value: "is an idea, not a to-do"
                // is a fact about the sentence, where "kind should be idea" is a fact about a
                // schema, and only one of those generalises.
                let to = CaptureKind.parse(lesson.to).phrase
                let from = CaptureKind.parse(lesson.from).phrase
                return "- \"\(lesson.taskTitle)\" is \(to), not \(from) — they reclassified it."
            case "effortMinutes":
                // Rendered as durations rather than raw integers: "4h, not 30m" is a fact about
                // the work, where "240, not 30" is a fact about a database column.
                let from = Int(lesson.from).map(TimeFormat.duration) ?? lesson.from
                let to = Int(lesson.to).map(TimeFormat.duration) ?? lesson.to
                return "- \"\(lesson.taskTitle)\" really takes \(to), not \(from)."
            default:
                return "- \"\(lesson.taskTitle)\": \(lesson.field) should be \(lesson.to), not \(lesson.from)."
            }
        }

        return """
        THIS USER'S CORRECTIONS. They previously changed your answers on these, so follow the \
        same judgement for anything similar. Their preference wins over your default:
        \(lines.joined(separator: "\n"))
        """
    }
}
