import Foundation

/// One entry on a day's timeline — either a real calendar event or a task due that day.
/// Merging both into a single ordered list is what makes the day readable at a glance:
/// commitments and intentions in one column, in the order they'll actually happen.
enum DayItem: Identifiable, Sendable {
    case event(CalendarEvent)
    case task(TaskItem)

    /// Prefixed so an event and a task can never collide in one list. **This is not a task id** —
    /// mistaking it for one is a real bug that shipped twice: both the grid's drag-to-move and the
    /// "Anytime" reorder passed this straight to a `store.allTasks.first { $0.id == id }` lookup,
    /// which silently never matched, so a dragged block sprang back and a reorder did nothing.
    /// Use `taskId` to get at the underlying task.
    var id: String {
        switch self {
        case let .event(e): return Self.eventIDPrefix + e.id
        case let .task(t):  return Self.taskIDPrefix + t.id
        }
    }

    static let taskIDPrefix = "task-"
    static let eventIDPrefix = "event-"

    /// The underlying task's id, or `nil` for an event.
    var taskId: String? {
        if case let .task(t) = self { return t.id }
        return nil
    }

    /// Recover a task id from an `id` produced above — one place that knows about the prefix, so
    /// callers holding only a row id can't get this wrong.
    static func taskId(fromItemID itemID: String) -> String? {
        guard itemID.hasPrefix(taskIDPrefix) else { return nil }
        return String(itemID.dropFirst(taskIDPrefix.count))
    }

    var title: String {
        switch self {
        case let .event(e): return e.title
        case let .task(t):  return t.title
        }
    }

    /// When it happens. `nil` for all-day events and undated tasks, which float to the
    /// bottom of the day rather than pretending to occupy a time.
    var time: Date? {
        switch self {
        case let .event(e): return e.isAllDay ? nil : e.start
        case let .task(t):  return DueDate.parse(t.dueDate)
        }
    }

    var isEvent: Bool {
        if case .event = self { return true }
        return false
    }
}

/// How much is happening on a given day — drives the month grid's density dots.
struct DayDensity: Sendable, Equatable {
    var tasks = 0
    var events = 0
    var hasHighPriority = false

    var isEmpty: Bool { tasks == 0 && events == 0 }
}

/// Pure merging of tasks + calendar events into day-shaped views. No EventKit, no database —
/// so every ordering rule here is unit-tested.
enum DayTimeline {

    /// Every day's timeline at once, keyed by start-of-day — the same single-pass bucketing
    /// `density` uses, and for the same reason.
    ///
    /// The Day tab's pager is a `.page`-style `TabView`, which is **not** lazy: it builds every
    /// page's body, so asking `items(tasks:events:on:)` for a day inside a page meant re-running
    /// the whole filter/sort pipeline once per page (61 of them) on every render — and again on
    /// every task write anywhere in the app, since the task stream is global. Bucketing once and
    /// looking a day up turns that back into one pass.
    static func itemsByDay(
        tasks: [TaskItem],
        events: [CalendarEvent],
        calendar: Calendar = .current
    ) -> [Date: [DayItem]] {
        // A task we turned into a calendar event would otherwise appear twice — once as the
        // task, once as the event we created from it. Show the task, since that's the thing
        // you can actually tick off.
        let ownEventIds = Set(tasks.compactMap(\.calendarEventId))

        // Events first, then tasks, so each bucket reaches `ordered` in the same order the
        // day-at-a-time version produced (`dayEvents + dayTasks`) — that decides ties the sort
        // itself can't.
        var buckets: [Date: [DayItem]] = [:]
        for event in events where !ownEventIds.contains(event.id) {
            buckets[calendar.startOfDay(for: event.start), default: []].append(.event(event))
        }
        // A step gets no row of its own: it belongs *inside* its parent's block (see
        // `StepLayout`), not beside it, where one piece of work reads as several unrelated ones.
        // The exception is an orphan — a step whose parent is finished or gone — which is
        // promoted rather than lost, the same rule `HomeGrouping.rootsOnly` applies.
        let livingIds = Set(tasks.filter { $0.status != "completed" && !$0.deleted }.map(\.id))
        for task in tasks where task.status != "completed" && !task.deleted {
            if let parent = task.parentTaskId, livingIds.contains(parent) { continue }
            guard let due = DueDate.parse(task.dueDate) else { continue }
            buckets[calendar.startOfDay(for: due), default: []].append(.task(task))
        }
        return buckets.mapValues(ordered)
    }

    /// Steps grouped under their parent's id — what the grid needs to draw a parent's block
    /// subdivided. The "living parent" test is deliberately the same one `itemsByDay` uses, so a
    /// step is either a slice or a row and never both or neither: a step whose parent is finished
    /// has no block to sit inside, and `itemsByDay` has already promoted it to a row of its own.
    ///
    /// A step's *own* completion doesn't exclude it — a finished step keeps its share of the span
    /// and renders struck through, which is what makes the block read as progress.
    static func stepsByParent(_ tasks: [TaskItem]) -> [String: [TaskItem]] {
        let livingIds = Set(tasks.filter { $0.status != "completed" && !$0.deleted }.map(\.id))
        var result: [String: [TaskItem]] = [:]
        for task in tasks where !task.deleted {
            guard let parent = task.parentTaskId, livingIds.contains(parent) else { continue }
            result[parent, default: []].append(task)
        }
        return result
    }

    /// The ordered timeline for one day: timed entries chronologically, then untimed ones
    /// (all-day events first, then undated tasks). Completed tasks are excluded — the
    /// timeline is about what's ahead.
    ///
    /// Deliberately a lookup into `itemsByDay` rather than its own filter pass: two
    /// implementations of "what belongs on this day" would eventually disagree, and the Day tab
    /// renders from the bucketed one. For a one-shot caller the cost is the same single pass.
    static func items(
        tasks: [TaskItem],
        events: [CalendarEvent],
        on day: Date,
        calendar: Calendar = .current
    ) -> [DayItem] {
        itemsByDay(tasks: tasks, events: events, calendar: calendar)[calendar.startOfDay(for: day)] ?? []
    }

    /// Sort timed items chronologically; untimed items keep events ahead of tasks, then sort
    /// by title so the order is stable rather than dependent on input order.
    ///
    /// Decorate–sort–undecorate: `DayItem.time` re-parses the task's stored due-date string, and a
    /// comparator runs O(n log n) times, so each item's time is resolved exactly once here.
    static func ordered(_ items: [DayItem]) -> [DayItem] {
        items
            .map { (item: $0, time: $0.time) }
            .sorted { a, b in
                switch (a.time, b.time) {
                case let (ta?, tb?):
                    if ta != tb { return ta < tb }
                case (_?, nil): return true       // timed before untimed
                case (nil, _?): return false
                case (nil, nil):
                    if a.item.isEvent != b.item.isEvent { return a.item.isEvent }   // all-day events before loose tasks
                }
                return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
            }
            .map(\.item)
    }

    /// Per-day counts keyed by start-of-day, for painting the month grid in one pass.
    static func density(
        tasks: [TaskItem],
        events: [CalendarEvent],
        calendar: Calendar = .current
    ) -> [Date: DayDensity] {
        var result: [Date: DayDensity] = [:]

        // Same rule as `itemsByDay`: a step is part of its parent's block, so counting it would
        // paint a day busier than it reads.
        let livingIds = Set(tasks.filter { $0.status != "completed" && !$0.deleted }.map(\.id))
        for task in tasks where task.status != "completed" && !task.deleted {
            if let parent = task.parentTaskId, livingIds.contains(parent) { continue }
            guard let due = DueDate.parse(task.dueDate) else { continue }
            let key = calendar.startOfDay(for: due)
            var entry = result[key] ?? DayDensity()
            entry.tasks += 1
            if task.priority == "high" { entry.hasHighPriority = true }
            result[key] = entry
        }

        for event in events {
            let key = calendar.startOfDay(for: event.start)
            var entry = result[key] ?? DayDensity()
            entry.events += 1
            result[key] = entry
        }
        return result
    }

    /// The days to render for a month grid: the whole month padded out to full weeks, so the
    /// grid is always a clean rectangle starting on the calendar's first weekday.
    static func monthGridDays(for month: Date, calendar: Calendar = .current) -> [Date] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: month),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return [] }

        // How many leading blanks before the 1st, given the locale's first weekday.
        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth) else { return [] }

        // Pad the tail so the final week is complete.
        let totalDays = leading + monthRange.count
        let cellCount = Int((Double(totalDays) / 7).rounded(.up)) * 7

        return (0..<cellCount).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }
}
