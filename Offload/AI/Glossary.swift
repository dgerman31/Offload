import Foundation

/// The words you use that a general model doesn't know.
///
/// REDCap, OSCE, shelf, H&P, path lecture, Anki. A model trained on everything has no idea that
/// "shelf" is an exam rather than furniture, and it will helpfully rewrite "H&P" into something
/// more sensible. Telling it your vocabulary up front costs a couple of dozen words in the prompt
/// and stops a whole class of mangled captures.
///
/// Learned purely from your own task titles — no dictionary, no upload, nothing leaves the phone.
/// The signal is repetition: a word you've used in five different tasks is a word that means
/// something to you, whatever the model thinks of it.
enum Glossary {

    /// How many *distinct* tasks a term has to appear in. Distinct, not total, so one task edited
    /// six times doesn't invent a term.
    static let minimumTasks = 3
    /// Kept short enough to sit in a prompt without crowding out the instructions that matter.
    static let limit = 25
    static let minimumLength = 2

    /// Ordinary English that repetition alone would otherwise promote. This list only needs to
    /// cover words common enough to clear `minimumTasks` in a task list — verbs, time words, and
    /// the vocabulary of to-do lists themselves.
    static let commonWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "about", "after", "before",
        "task", "tasks", "todo", "list", "notes", "note", "email", "call", "text", "meeting",
        "buy", "get", "make", "send", "finish", "start", "check", "read", "write", "review",
        "plan", "book", "pay", "fix", "clean", "order", "pick", "drop", "week", "weekly",
        "day", "daily", "today", "tomorrow", "morning", "night", "evening", "afternoon",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "work", "home", "personal", "study", "health", "admin", "school", "class", "classes",
        "hour", "hours", "min", "mins", "minute", "minutes", "time", "times", "new", "old",
        "next", "last", "this", "that", "some", "all", "more", "less", "back", "out", "off"
    ]

    /// Terms worth telling the model about, most-used first.
    ///
    /// Casing is preserved from the way you actually write the word — "REDCap" tells the model far
    /// more than "redcap" does, since the capitalisation is itself the signal that it's a proper
    /// noun rather than a compound of "red" and "cap".
    static func learn(tasks: [TaskItem], limit: Int = Glossary.limit) -> [String] {
        var taskCounts: [String: Int] = [:]        // lowercased term → distinct tasks
        var casings: [String: [String: Int]] = [:] // lowercased term → seen casing → count

        for task in tasks where !task.deleted {
            var seenHere = Set<String>()
            for raw in words(in: task.title) {
                let lower = raw.lowercased()
                guard lower.count >= minimumLength, !commonWords.contains(lower), Int(lower) == nil else { continue }
                casings[lower, default: [:]][raw, default: 0] += 1
                guard seenHere.insert(lower).inserted else { continue }
                taskCounts[lower, default: 0] += 1
            }
        }

        return taskCounts
            .filter { $0.value >= minimumTasks }
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(limit)
            .map { term, _ in
                // The casing you use most often. Ties go to the more distinctive form, so a term
                // written "REDCap" twice and "redcap" twice is remembered as "REDCap".
                let seen = casings[term] ?? [:]
                return seen.max { a, b in
                    a.value != b.value ? a.value < b.value : isPlain(a.key) && !isPlain(b.key)
                }?.key ?? term
            }
    }

    /// Split a title into candidate terms, keeping the shapes that carry meaning: `H&P` and
    /// `follow-up` survive intact rather than being shredded into single letters.
    static func words(in title: String) -> [String] {
        title
            .split(whereSeparator: { $0.isWhitespace || ",.;:!?()[]\"'/".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-&")) }
            .filter { !$0.isEmpty }
    }

    /// A prompt block naming the user's vocabulary. `nil` when nothing's been learned, so a new
    /// user's prompt stays clean.
    static func promptFragment(_ terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return """
        THIS USER'S VOCABULARY: \(terms.joined(separator: ", ")). \
        These are their own terms — coursework, tools, places, people. Keep them verbatim in \
        titles, never expand, translate, or "correct" them, and never split one into several tasks.
        """
    }

    /// Whether a term is written in ordinary lowercase, as opposed to something distinctive like
    /// REDCap or OSCE.
    private static func isPlain(_ term: String) -> Bool {
        term == term.lowercased()
    }
}
