import Foundation

/// Relationship memory (spec §4, feature 10).
///
/// A lot of what people carry isn't "tasks" — it's *obligations to other people*: the reply
/// you owe, the thing you promised to send, the person you said you'd call back. Those are
/// exactly the loops that nag hardest, and they're invisible in a flat list.
///
/// Names are extracted at capture time and stored per task, so "what do I owe Sarah?" becomes
/// a query. All of it stays on-device — the app knows who's in your life and that never leaves
/// the phone, which is precisely the trade a cloud task manager can't offer.
enum People {

    /// One person and everything outstanding with them.
    struct Commitment: Identifiable, Sendable, Equatable {
        var name: String
        var open: [TaskItem]
        var overdueCount: Int
        var id: String { name.lowercased() }

        var isEmpty: Bool { open.isEmpty }
    }

    /// Names are stored as a JSON array; anything malformed is simply ignored.
    static func decode(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    /// Encode names for storage: trimmed, de-duplicated case-insensitively (so "sarah" and
    /// "Sarah" are one person), capped so a rambling capture can't fill the column.
    static func encode(_ names: [String]) -> String? {
        var seen = Set<String>()
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                guard name.count >= 2, name.count <= 40 else { return false }
                return seen.insert(name.lowercased()).inserted
            }
            .prefix(5)

        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(Array(cleaned)),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Group open work by person, busiest first. Completed and deleted tasks drop out — an
    /// obligation you've already met shouldn't still appear as owed.
    static func commitments(from tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [Commitment] {
        let startOfToday = calendar.startOfDay(for: now)
        var byPerson: [String: (display: String, tasks: [TaskItem], overdue: Int)] = [:]

        for task in tasks where task.status != "completed" && !task.deleted {
            for name in decode(task.people) {
                let key = name.lowercased()
                var entry = byPerson[key] ?? (display: name, tasks: [], overdue: 0)
                entry.tasks.append(task)
                if let due = DueDate.parse(task.dueDate), due < startOfToday {
                    entry.overdue += 1
                }
                byPerson[key] = entry
            }
        }

        return byPerson.values
            .map { Commitment(name: $0.display, open: HomeGrouping.inDisplayOrder($0.tasks), overdueCount: $0.overdue) }
            .sorted { a, b in
                if a.overdueCount != b.overdueCount { return a.overdueCount > b.overdueCount }
                if a.open.count != b.open.count { return a.open.count > b.open.count }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// A one-line answer to "what do I owe them?"
    static func summary(for commitment: Commitment) -> String {
        var parts = ["\(commitment.open.count) open"]
        if commitment.overdueCount > 0 { parts.append("\(commitment.overdueCount) overdue") }
        return parts.joined(separator: " · ")
    }
}
