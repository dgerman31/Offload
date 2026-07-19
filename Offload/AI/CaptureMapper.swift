import Foundation

/// Converts the model's `ExtractedCapture` into domain records ready for SQLite.
/// Pure and deterministic — no model calls — so it's fully unit-testable.
enum CaptureMapper {

    /// The valid category set (spec §4, feature 3). Anything off-list falls back to "Other".
    static let categories: Set<String> = [
        "Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"
    ]
    static let priorities: Set<String> = ["high", "medium", "low"]

    /// The fixed context-tag vocabulary — anything the model invents outside this is dropped.
    static let allowedContextTags: Set<String> = [
        "home", "work", "car", "outside", "store", "gym", "phone", "computer", "meeting", "errands"
    ]

    /// Minimum tasks before a capture is allowed to become a project — keeps single
    /// everyday tasks from being over-organized into projects (user feedback).
    static let minTasksForProject = 2

    struct Result {
        var project: Project?
        var tasks: [TaskItem]
        /// Ids of tasks the model classified as real calendar appointments *and* that carry a
        /// due date — the ones the capture pipeline turns into EventKit events (spec §3.3 write).
        var appointmentTaskIds: Set<String> = []
    }

    /// Build a `Project` (only for genuine multi-step clusters) and the `TaskItem`s, linked to it.
    static func map(_ extracted: ExtractedCapture) -> Result {
        let project: Project? = {
            guard extracted.tasks.count >= minTasksForProject,
                  let name = extracted.suggestedProject?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return Project(title: name)
        }()

        var tasks: [TaskItem] = []
        var appointmentTaskIds: Set<String> = []
        for t in extracted.tasks {
            let dueDate = DueDate.normalize(t.dueDate)
            let parent = TaskItem(
                title: t.title.trimmingCharacters(in: .whitespacesAndNewlines),
                category: normalizedCategory(t.category),
                priority: normalizedPriority(t.priority),
                projectId: project?.id,
                dueDate: dueDate,
                dueDateConfidence: dueDate == nil ? nil : 0.5,
                recurrenceRule: nonEmpty(t.recurrenceRule),
                contextTags: encodeTags(t.contextTags),
                effortMinutes: t.effortMinutes
            )
            tasks.append(parent)
            // Only a real, time-anchored appointment becomes a calendar event.
            if t.isAppointment, dueDate != nil {
                appointmentTaskIds.insert(parent.id)
            }

            // Hierarchical extraction (spec feature 1), but restrained (punch list #4): sub-steps
            // become child tasks only when there are ≥2 genuinely distinct steps that don't just
            // restate the errand. They inherit the parent's category/priority/context.
            for title in restrainedSubtasks(parentTitle: parent.title, subtasks: t.subtasks) {
                tasks.append(TaskItem(
                    title: title,
                    category: parent.category,
                    priority: parent.priority,
                    parentTaskId: parent.id,
                    projectId: project?.id,
                    contextTags: parent.contextTags
                ))
            }
        }
        return Result(project: project, tasks: tasks, appointmentTaskIds: appointmentTaskIds)
    }

    /// Guard against over-decomposition (punch list #4). Keeps subtasks ONLY when there are at
    /// least two genuinely distinct sub-steps, dropping any that merely restate the parent
    /// errand (e.g. parent "Buy milk" with a subtask "Buy milk", or "Go to the store to buy
    /// milk" with a subtask "Buy milk"). Fewer than two distinct steps → the task stands alone.
    static func restrainedSubtasks(parentTitle: String, subtasks: [String]) -> [String] {
        let parent = normalizedForComparison(parentTitle)
        var seen = Set<String>()
        var kept: [String] = []
        for raw in subtasks {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let norm = normalizedForComparison(title)
            guard !norm.isEmpty else { continue }
            // Drop anything that restates the parent errand (either direction).
            if norm == parent || (!parent.isEmpty && (parent.contains(norm) || norm.contains(parent))) { continue }
            guard seen.insert(norm).inserted else { continue }   // collapse duplicates
            kept.append(title)
        }
        return kept.count >= 2 ? kept : []
    }

    /// Lowercased, alphanumerics-and-spaces-only, whitespace-collapsed form for the restraint
    /// comparison above — so punctuation and casing don't hide a restatement.
    private static func normalizedForComparison(_ s: String) -> String {
        let cleaned = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // MARK: Helpers

    static func normalizedCategory(_ raw: String) -> String {
        categories.contains(raw) ? raw : "Other"
    }

    static func normalizedPriority(_ raw: String) -> String {
        priorities.contains(raw) ? raw : "medium"
    }

    /// Encode context tags as a JSON array string: lowercased, restricted to the allowed
    /// vocabulary, de-duplicated, order-preserving. Returns nil when nothing valid remains.
    static func encodeTags(_ tags: [String]) -> String? {
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { allowedContextTags.contains($0) && seen.insert($0).inserted }
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
