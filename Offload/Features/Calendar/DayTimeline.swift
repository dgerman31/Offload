import Foundation

/// One entry on a day's timeline — either a real calendar event or a task due that day.
/// Merging both into a single ordered list is what makes the day readable at a glance:
/// commitments and intentions in one column, in the order they'll actually happen.
enum DayItem: Identifiable, Sendable {
    case event(CalendarEvent)
    case task(TaskItem)

    var id: String {
        switch self {
        case let .event(e): return "event-\(e.id)"
        case let .task(t):  return "task-\(t.id)"
        }
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

    /// The ordered timeline for one day: timed entries chronologically, then untimed ones
    /// (all-day events first, then undated tasks). Completed tasks are excluded — the
    /// timeline is about what's ahead.
    static func items(
        tasks: [TaskItem],
        events: [CalendarEvent],
        on day: Date,
        calendar: Calendar = .current
    ) -> [DayItem] {
        let dayEvents = events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .map { DayItem.event($0) }

        let dayTasks = tasks
            .filter { $0.status != "completed" && !$0.deleted }
            .filter { task in
                guard let due = DueDate.parse(task.dueDate) else { return false }
                return calendar.isDate(due, inSameDayAs: day)
            }
            .map { DayItem.task($0) }

        return ordered(dayEvents + dayTasks)
    }

    /// Sort timed items chronologically; untimed items keep events ahead of tasks, then sort
    /// by title so the order is stable rather than dependent on input order.
    static func ordered(_ items: [DayItem]) -> [DayItem] {
        items.sorted { a, b in
            switch (a.time, b.time) {
            case let (ta?, tb?):
                if ta != tb { return ta < tb }
            case (_?, nil): return true       // timed before untimed
            case (nil, _?): return false
            case (nil, nil):
                if a.isEvent != b.isEvent { return a.isEvent }   // all-day events before loose tasks
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Per-day counts keyed by start-of-day, for painting the month grid in one pass.
    static func density(
        tasks: [TaskItem],
        events: [CalendarEvent],
        calendar: Calendar = .current
    ) -> [Date: DayDensity] {
        var result: [Date: DayDensity] = [:]

        for task in tasks where task.status != "completed" && !task.deleted {
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
