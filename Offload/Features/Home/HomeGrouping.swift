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

/// Groups Home into pressing sections first — **Overdue**, then **Focus** (high priority or
/// due today) — followed by per-category sections in a stable order, so what needs the user
/// surfaces without hunting. Within every section tasks are ordered by urgency (priority, then
/// soonest due date, then title) rather than capture order. Subtasks are interleaved directly
/// beneath their parent, indented. Pure + testable.
enum HomeGrouping {
    static let categoryOrder = ["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]

    private static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high": return 0
        case "low": return 2
        default: return 1
        }
    }

    /// Most-pressing first: higher priority, then the soonest due date (dated tasks before
    /// undated ones), then title for a stable, predictable order. Pure — safe to unit-test.
    static func inDisplayOrder(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { a, b in
            let pa = priorityRank(a.priority), pb = priorityRank(b.priority)
            if pa != pb { return pa < pb }
            switch (DueDate.parse(a.dueDate), DueDate.parse(b.dueDate)) {
            case let (da?, db?) where da != db: return da < db
            case (_?, nil): return true    // a dated task outranks an undated one
            case (nil, _?): return false
            default: break
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    static func sections(from tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskSection] {
        let startOfToday = calendar.startOfDay(for: now)
        func isOverdue(_ s: String?) -> Bool {
            guard let d = DueDate.parse(s) else { return false }
            return d < startOfToday          // due before today = overdue (later today is not)
        }
        func dueToday(_ s: String?) -> Bool {
            guard let d = DueDate.parse(s) else { return false }
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

        // Overdue outranks Focus so a past-due task never hides among today's work; each root
        // lands in exactly one bucket.
        var overdue: [TaskItem] = []
        var focus: [TaskItem] = []
        var rest: [TaskItem] = []
        for task in roots {
            if isOverdue(task.dueDate) {
                overdue.append(task)
            } else if task.priority == "high" || dueToday(task.dueDate) {
                focus.append(task)
            } else {
                rest.append(task)
            }
        }

        /// Order roots by urgency, then interleave each with its children (indented).
        func rows(_ list: [TaskItem]) -> [TaskRowItem] {
            inDisplayOrder(list).flatMap { root in
                [TaskRowItem(task: root, indented: false)]
                + (childMap[root.id] ?? []).map { TaskRowItem(task: $0, indented: true) }
            }
        }

        var sections: [TaskSection] = []
        if !overdue.isEmpty { sections.append(TaskSection(title: "Overdue", rows: rows(overdue))) }
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
