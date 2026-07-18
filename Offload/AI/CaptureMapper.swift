import Foundation

/// Converts the model's `ExtractedCapture` into domain records ready for SQLite.
/// Pure and deterministic — no model calls — so it's fully unit-testable.
enum CaptureMapper {

    /// The valid category set (spec §4, feature 3). Anything off-list falls back to "Other".
    static let categories: Set<String> = [
        "Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"
    ]
    static let priorities: Set<String> = ["high", "medium", "low"]

    struct Result {
        var project: Project?
        var tasks: [TaskItem]
    }

    /// Build a `Project` (if the model suggested one) and the `TaskItem`s, linked to it.
    static func map(_ extracted: ExtractedCapture) -> Result {
        let project: Project? = extracted.suggestedProject
            .flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Project(title: trimmed)
            }

        let tasks = extracted.tasks.map { t in
            TaskItem(
                title: t.title.trimmingCharacters(in: .whitespacesAndNewlines),
                category: normalizedCategory(t.category),
                priority: normalizedPriority(t.priority),
                projectId: project?.id,
                dueDate: nonEmpty(t.dueDate),
                dueDateConfidence: nonEmpty(t.dueDate) == nil ? nil : 0.5,
                recurrenceRule: nonEmpty(t.recurrenceRule),
                contextTags: encodeTags(t.contextTags),
                effortMinutes: t.effortMinutes
            )
        }
        return Result(project: project, tasks: tasks)
    }

    // MARK: Helpers

    static func normalizedCategory(_ raw: String) -> String {
        categories.contains(raw) ? raw : "Other"
    }

    static func normalizedPriority(_ raw: String) -> String {
        priorities.contains(raw) ? raw : "medium"
    }

    /// Encode context tags as a JSON array string for the `context_tags` column.
    static func encodeTags(_ tags: [String]) -> String? {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
