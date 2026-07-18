import Foundation

/// One display row: a task and whether it renders indented (as a subtask).
struct TaskRowItem: Identifiable, Sendable {
    let task: TaskItem
    let indented: Bool
    var id: String { task.id }
}

struct TaskSection: Identifiable, Sendable {
    let title: String
    let rows: [TaskRowItem]
    var id: String { title }

    /// Convenience for tests / callers that only care about the tasks.
    var tasks: [TaskItem] { rows.map(\.task) }
}

/// Groups Home into a pinned "Focus" section (high priority or due today) followed by
/// per-category sections in a stable order — so Home stays scannable as tasks pile up.
/// Subtasks are interleaved directly beneath their parent, indented. Pure + testable.
enum HomeGrouping {
    static let categoryOrder = ["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]

    static func sections(from tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskSection] {
        let iso = ISO8601DateFormatter()
        func dueToday(_ s: String?) -> Bool {
            guard let s, let d = iso.date(from: s) else { return false }
            return calendar.isDate(d, inSameDayAs: now)
        }

        // Split top-level tasks from children; orphaned children (parent completed or
        // deleted, so absent from this list) are promoted to top-level rather than lost.
        let topLevel = tasks.filter { $0.parentTaskId == nil }
        let topIds = Set(topLevel.map(\.id))
        var childMap: [String: [TaskItem]] = [:]
        var orphans: [TaskItem] = []
        for task in tasks where task.parentTaskId != nil {
            if let parent = task.parentTaskId, topIds.contains(parent) {
                childMap[parent, default: []].append(task)
            } else {
                orphans.append(task)
            }
        }
        let roots = topLevel + orphans

        var focus: [TaskItem] = []
        var rest: [TaskItem] = []
        for task in roots {
            if task.priority == "high" || dueToday(task.dueDate) {
                focus.append(task)
            } else {
                rest.append(task)
            }
        }

        /// Interleave: each root followed by its children, indented.
        func rows(_ list: [TaskItem]) -> [TaskRowItem] {
            list.flatMap { root in
                [TaskRowItem(task: root, indented: false)]
                + (childMap[root.id] ?? []).map { TaskRowItem(task: $0, indented: true) }
            }
        }

        var sections: [TaskSection] = []
        if !focus.isEmpty { sections.append(TaskSection(title: "Focus", rows: rows(focus))) }

        let byCategory = Dictionary(grouping: rest) { $0.category ?? "Other" }
        for category in categoryOrder {
            if let items = byCategory[category], !items.isEmpty {
                sections.append(TaskSection(title: category, rows: rows(items)))
            }
        }
        for (category, items) in byCategory where !categoryOrder.contains(category) {
            sections.append(TaskSection(title: category, rows: rows(items)))
        }
        return sections
    }
}
