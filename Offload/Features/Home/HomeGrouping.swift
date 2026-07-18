import Foundation

struct TaskSection: Identifiable, Sendable {
    let title: String
    let tasks: [TaskItem]
    var id: String { title }
}

/// Groups Home into a pinned "Focus" section (high priority or due today) followed by
/// per-category sections in a stable order — so Home stays scannable as tasks pile up.
/// Pure + testable.
enum HomeGrouping {
    static let categoryOrder = ["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]

    static func sections(from tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskSection] {
        let iso = ISO8601DateFormatter()
        func dueToday(_ s: String?) -> Bool {
            guard let s, let d = iso.date(from: s) else { return false }
            return calendar.isDate(d, inSameDayAs: now)
        }

        var focus: [TaskItem] = []
        var rest: [TaskItem] = []
        for task in tasks {
            if task.priority == "high" || dueToday(task.dueDate) {
                focus.append(task)
            } else {
                rest.append(task)
            }
        }

        var sections: [TaskSection] = []
        if !focus.isEmpty { sections.append(TaskSection(title: "Focus", tasks: focus)) }

        let byCategory = Dictionary(grouping: rest) { $0.category ?? "Other" }
        for category in categoryOrder {
            if let items = byCategory[category], !items.isEmpty {
                sections.append(TaskSection(title: category, tasks: items))
            }
        }
        // Any unexpected categories (shouldn't happen — mapper normalizes) go last.
        for (category, items) in byCategory where !categoryOrder.contains(category) {
            sections.append(TaskSection(title: category, tasks: items))
        }
        return sections
    }
}
