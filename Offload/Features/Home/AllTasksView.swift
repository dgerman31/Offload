import SwiftUI

/// Every open task, grouped by due-date proximity so "everything" still reads as a handful of
/// scannable buckets instead of one long wall. Home deliberately shows only a curated subset
/// (hero, pinned, Next, suggestions, the "On your list" running list) — this is the screen for
/// "no really, show me all of it".
///
/// Pure grouping lives in `AllTasksGrouping`, the counterpart to `HomeGrouping` (which pins by
/// urgency/category instead of a due-date calendar). Both share `TaskSection`/`TaskRowItem`.
struct AllTasksView: View {
    @State private var store = TaskStore()
    @State private var editing: TaskItem?
    @State private var appeared = false

    /// Recomputed from whatever the shared task stream last delivered — no ticking clock here.
    /// Unlike Home's live "is this overdue *right now*" ring, a coarse day-level bucket doesn't
    /// go stale between one render and the next; it only needs to be right whenever the screen
    /// happens to redraw, which task edits already trigger.
    private var sections: [TaskSection] {
        AllTasksGrouping.sections(from: store.openTasks, now: Date())
    }

    /// A quiet count, not a section of its own — this screen is about what's still open, and
    /// finished work shouldn't compete with that for space.
    private var completedTodayCount: Int {
        let calendar = Calendar.current
        let now = Date()
        return store.allTasks.filter { task in
            guard task.status == "completed" else { return false }
            guard let done = DueDate.parse(task.completedAt) else { return false }
            return calendar.isDate(done, inSameDayAs: now)
        }.count
    }

    var body: some View {
        // Computed once per body evaluation rather than read at each call site — the grouping
        // walks every open task, and this screen exists precisely because that list can be long.
        let currentSections = sections
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if currentSections.isEmpty {
                    Text("Nothing open right now.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(Array(currentSections.enumerated()), id: \.element.id) { index, section in
                        sectionCard(section)
                            .appearIn(index, when: appeared)
                            .scrollAppear()
                    }
                }
                if completedTodayCount > 0 {
                    Text("\(completedTodayCount) completed today")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .closesSwipeRailsOnScroll()
        .background(Color.Offload.background)
        .navigationTitle("All Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .task { withAnimation(Motion.settle) { appeared = true } }
        .sheet(item: $editing) { task in
            NavigationStack { TaskDetailView(task: task) }
        }
    }

    private func sectionCard(_ section: TaskSection) -> some View {
        let (icon, tint) = style(for: section.title)
        return VStack(alignment: .leading, spacing: 14) {
            Label(section.title, systemImage: icon)
                .font(.caption2).fontWeight(.bold)
                .foregroundStyle(tint)
            VStack(spacing: 2) {
                ForEach(section.rows) { row in
                    rowView(row)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    /// Same row-building block Home uses for its own list: `onEdit: nil` so the row's tap-to-open
    /// moves to `.swipeToDelete`'s `onTap` instead of a second, independent gesture recognizer
    /// racing the swipe on the same touch.
    private func rowView(_ row: TaskRowItem) -> some View {
        TaskRowView(task: row.task, indented: row.indented, onEdit: nil) {
            Task { await store.toggleComplete(row.task) }
        }
        .contextMenu { TaskContextMenu(task: row.task, onFocus: { FocusTimer.shared.start(task: $0) }, onEdit: openTask) }
        .swipeToDelete(id: row.task.id, onTap: { openTask(row.task) }) {
            Task { await store.delete(row.task) }
        }
    }

    /// A task that's really the schedule block for a Gym-tab session opens the Gym tab to that
    /// session instead of the normal task detail — its real content lives only there. Mirrors
    /// `EverythingView.openTask` exactly, since a task found here can be the same one found there.
    private func openTask(_ task: TaskItem) {
        if let gymSessionId = task.gymSessionId {
            AppNavigation.shared.openGymSession(gymSessionId)
        } else {
            editing = task
        }
    }

    /// Calm, purposeful icon/tint per bucket — Overdue earns the one warm color on this screen;
    /// everything else stays quiet so the list doesn't read as alarmed.
    private func style(for title: String) -> (String, Color) {
        switch title {
        case "Overdue":   return ("exclamationmark.circle.fill", Color.Offload.red)
        case "Today":     return ("sun.max.fill", Color.Offload.indigoText)
        case "Tomorrow":  return ("sunrise.fill", Color.Offload.teal)
        case "This week": return ("calendar", Color.Offload.muted)
        case "Later":     return ("calendar.badge.clock", Color.Offload.muted)
        default:          return ("tray.fill", Color.Offload.muted)   // Anytime
        }
    }
}

/// Groups every open task by due-date proximity — Overdue, Today, Tomorrow, This week, Later,
/// Anytime (no date) — the calendar-shaped counterpart to `HomeGrouping.sections`, which instead
/// pins by urgency/category for Home's curated view. Pure + testable; steps nest under their
/// parent exactly the way `HomeGrouping.sections` nests them, via the same `TaskRowItem.indented`
/// convention, so a task's breakdown never appears as loose rows beside it.
enum AllTasksGrouping {
    static let order = ["Overdue", "Today", "Tomorrow", "This week", "Later", "Anytime"]

    static func sections(from tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskSection] {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
        // A reference moment for "tomorrow" independent of `now`'s time-of-day, so a 11pm `now`
        // and a 6am `now` bucket the same due date identically.
        let tomorrowRef = calendar.date(byAdding: .day, value: 1, to: now) ?? now

        func bucket(_ task: TaskItem) -> String {
            guard let due = DueDate.parse(task.dueDate) else { return "Anytime" }
            if due < startOfToday { return "Overdue" }
            if calendar.isDate(due, inSameDayAs: now) { return "Today" }
            if calendar.isDate(due, inSameDayAs: tomorrowRef) { return "Tomorrow" }
            if due < endOfWeek { return "This week" }
            return "Later"
        }

        // Same root/child split `HomeGrouping.sections` uses: only real roots (or orphaned steps
        // whose parent isn't in this list) get their own row; a step nests under its live parent.
        let roots = HomeGrouping.rootsOnly(tasks)
        let rootIds = Set(roots.map(\.id))
        var childMap: [String: [TaskItem]] = [:]
        for task in tasks where task.parentTaskId != nil {
            if let parent = task.parentTaskId, rootIds.contains(parent) {
                childMap[parent, default: []].append(task)
            }
        }

        var buckets: [String: [TaskItem]] = [:]
        for task in roots {
            buckets[bucket(task), default: []].append(task)
        }

        func rows(_ list: [TaskItem]) -> [TaskRowItem] {
            HomeGrouping.inDisplayOrder(list).flatMap { root in
                [TaskRowItem(task: root, indented: false)]
                + (childMap[root.id] ?? []).map { TaskRowItem(task: $0, indented: true) }
            }
        }

        return order.compactMap { title in
            guard let items = buckets[title], !items.isEmpty else { return nil }
            return TaskSection(title: title, rows: rows(items))
        }
    }
}
