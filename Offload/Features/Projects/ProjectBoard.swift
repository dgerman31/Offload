import Foundation

/// How a project's contents are arranged on screen.
///
/// A project used to be a flat to-do list with a Done pile under it, which is why a capture full of
/// ideas came back looking like a chore list: there was nowhere else for anything to go. Now the
/// contents are grouped by what they *are* — next actions, things you're waiting on, open
/// questions, ideas, decisions, notes — and each group behaves according to its kind.
///
/// Pure and static, so the arrangement is unit-tested rather than inspected by scrolling.
enum ProjectBoard {

    /// One heading and the rows under it.
    struct Section: Identifiable, Equatable, Sendable {
        /// The kind that names the section. Where several kinds share a heading (a task and a
        /// commitment are both "Next actions"), this is the first one seen.
        let kind: CaptureKind
        let title: String
        let items: [TaskItem]

        var id: String { title }
        /// Rows here can be ticked off.
        var isCheckable: Bool { kind.isCheckable }
    }

    /// Everything still open, grouped and ordered.
    ///
    /// Steps are left out: they belong inside their parent's row, not loose beside it. Same rule
    /// the planner, the day timeline and the shutdown already apply — a parent with four steps
    /// would otherwise quintuple the length of the section it's in.
    static func sections(_ tasks: [TaskItem]) -> [Section] {
        let living = tasks.filter { !$0.deleted }
        let openIds = Set(living.filter { !isDone($0) }.map(\.id))
        let open = living.filter { task in
            guard !isDone(task) else { return false }
            // A step whose parent is still open belongs inside that parent's row. One whose parent
            // is finished or gone is an orphan, and is promoted here rather than lost — the same
            // rule `HomeGrouping.rootsOnly` and the day timeline already apply.
            if let parent = task.parentTaskId, openIds.contains(parent) { return false }
            return true
        }

        var buckets: [String: (kind: CaptureKind, items: [TaskItem])] = [:]
        for task in open {
            let kind = task.captureKind
            let title = kind.sectionTitle
            if buckets[title] == nil {
                buckets[title] = (kind, [task])
            } else {
                buckets[title]?.items.append(task)
            }
        }

        return buckets
            .map { Section(kind: $0.value.kind, title: $0.key, items: ordered($0.value.items)) }
            .sorted { lhs, rhs in
                if lhs.kind.sectionRank != rhs.kind.sectionRank { return lhs.kind.sectionRank < rhs.kind.sectionRank }
                return lhs.title < rhs.title
            }
    }

    /// Finished work, newest first — the record of what this project has actually produced.
    ///
    /// Only kinds that *can* be finished appear. A note isn't done, it's just a note, and putting
    /// notes in a Done pile would quietly make a project's reference material look like progress.
    static func done(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks
            .filter { !$0.deleted && $0.captureKind.isCheckable && isDone($0) }
            .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
    }

    /// The one thing that would move this project forward.
    ///
    /// Straight from GTD, and it's the question a project view exists to answer: not "what's in
    /// this project" but "what do I do about it". The top of the ordered Next actions — manual
    /// order first, which means dragging a row to the top *is* how you nominate it.
    static func nextAction(_ tasks: [TaskItem]) -> TaskItem? {
        sections(tasks).first { $0.kind.sectionTitle == CaptureKind.task.sectionTitle }?.items.first
    }

    /// Open counts for the header. Ideas and notes are excluded from "open" on purpose — a project
    /// with thirty ideas and two tasks is not twenty-eight units of work behind.
    static func openWorkCount(_ tasks: [TaskItem]) -> Int {
        tasks.filter { !$0.deleted && !isDone($0) && $0.captureKind.isSchedulable }.count
    }

    /// Days until the project's target date, or nil if it hasn't got one.
    static func daysRemaining(_ project: Project, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let due = DueDate.parse(project.dueDate) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: due)).day
    }

    /// The header's one-line status. Says the most useful true thing, and says nothing rather than
    /// padding — a header that always has something to report trains you to stop reading it.
    static func runway(_ project: Project, tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> String? {
        let open = openWorkCount(tasks)
        guard let days = daysRemaining(project, now: now, calendar: calendar) else {
            return open == 0 ? nil : "\(open) thing\(open == 1 ? "" : "s") to do"
        }
        if days < 0 { return "Target date passed" }
        let dayText = days == 0 ? "Due today" : (days == 1 ? "1 day left" : "\(days) days left")
        guard open > 0 else { return dayText }
        return "\(dayText) · \(open) to do"
    }

    private static func isDone(_ task: TaskItem) -> Bool { task.status == "completed" }

    /// Manual order first, then capture order — the same rule the old to-do list used, kept so
    /// dragging still means what it meant.
    private static func ordered(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            let lo = lhs.sortOrder ?? .greatestFiniteMagnitude
            let ro = rhs.sortOrder ?? .greatestFiniteMagnitude
            if lo != ro { return lo < ro }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
