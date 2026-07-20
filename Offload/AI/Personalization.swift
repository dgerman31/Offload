import Foundation

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
    static let learnableFields: Set<String> = ["category", "priority"]

    /// Build lessons from raw corrections, newest first. Keeps only the most recent correction
    /// per task+field (so repeatedly editing one task doesn't drown out everything else), drops
    /// no-op corrections, and de-duplicates identical lessons.
    static func lessons(
        corrections: [Correction],
        tasks: [TaskItem],
        limit: Int = 6
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
            if result.count >= limit { break }
        }
        return result
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
