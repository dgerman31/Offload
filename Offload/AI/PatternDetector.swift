import Foundation

/// Deterministic pattern detection (spec §3.6 / feature 7). Pure and testable; the
/// service layer persists results as dismissible `Pattern` suggestions — background
/// passes never mutate tasks silently.
enum PatternDetector {

    // MARK: Recurrence

    struct RecurrenceSuggestion: Equatable {
        let normalizedTitle: String
        let displayTitle: String
        let taskIds: [String]
        let suggestedRule: String   // iCalendar RRULE
        let cadenceLabel: String    // "daily" | "weekly" | "monthly"
    }

    /// Lowercased, punctuation-stripped, whitespace-collapsed title key.
    static func normalize(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Tasks captured ≥ `minOccurrences` times under the same normalized title, none of
    /// which already recur → suggest a recurrence with cadence inferred from capture gaps.
    static func recurrenceSuggestions(
        tasks: [TaskItem],
        minOccurrences: Int = 3
    ) -> [RecurrenceSuggestion] {
        let iso = ISO8601DateFormatter()
        let groups = Dictionary(grouping: tasks.filter { !$0.title.isEmpty }) { normalize($0.title) }

        return groups.compactMap { key, members in
            guard !key.isEmpty,
                  members.count >= minOccurrences,
                  members.allSatisfy({ ($0.recurrenceRule ?? "").isEmpty })
            else { return nil }

            let dates = members.compactMap { iso.date(from: $0.createdAt) }.sorted()
            let (rule, label) = Self.cadence(from: dates)
            return RecurrenceSuggestion(
                normalizedTitle: key,
                displayTitle: members.sorted { $0.createdAt > $1.createdAt }.first?.title ?? key,
                taskIds: members.map(\.id),
                suggestedRule: rule,
                cadenceLabel: label
            )
        }
        .sorted { $0.taskIds.count > $1.taskIds.count }
    }

    /// Median gap between captures → DAILY (≤1.5d), WEEKLY (≤10d), else MONTHLY.
    static func cadence(from dates: [Date]) -> (rule: String, label: String) {
        guard dates.count >= 2 else { return ("FREQ=WEEKLY", "weekly") }
        let gaps = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) / 86_400 }
        let median = gaps.sorted()[gaps.count / 2]
        switch median {
        case ..<1.5:  return ("FREQ=DAILY", "daily")
        case ..<10:   return ("FREQ=WEEKLY", "weekly")
        default:      return ("FREQ=MONTHLY", "monthly")
        }
    }

    // MARK: Breakdown ("this keeps slipping")

    struct BreakdownSuggestion: Equatable {
        let taskId: String
        let title: String
        let overdueDays: Int
    }

    /// Open, childless tasks overdue by more than `minOverdueDays` → suggest breaking down.
    static func breakdownSuggestions(
        tasks: [TaskItem],
        now: Date,
        minOverdueDays: Int = 3
    ) -> [BreakdownSuggestion] {
        let iso = ISO8601DateFormatter()
        let parentIds = Set(tasks.compactMap(\.parentTaskId))

        return tasks.compactMap { task in
            guard task.status != "completed",
                  !parentIds.contains(task.id),           // already broken down
                  task.parentTaskId == nil,               // don't nag about subtasks
                  let dueString = task.dueDate,
                  let due = iso.date(from: dueString)
            else { return nil }
            let overdue = Int(now.timeIntervalSince(due) / 86_400)
            guard overdue > minOverdueDays else { return nil }
            return BreakdownSuggestion(taskId: task.id, title: task.title, overdueDays: overdue)
        }
        .sorted { $0.overdueDays > $1.overdueDays }
    }
}
