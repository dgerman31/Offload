import Foundation

/// Turns routines into the concrete sessions that appear on a given day.
///
/// Two jobs. Fixed routines (a class that meets Mon/Wed/Fri) simply occur on their weekdays,
/// minus any one-off cancellations. Flexible routines (gym 4–5× a week) are the interesting
/// part: the app decides *which* days, spending sessions on your lightest days and leaving the
/// heaviest as rest — so the schedule bends around the rest of your life instead of nagging you
/// to train on your worst day.
///
/// Pure and deterministic; the service layer just persists what this produces.
enum RoutinePlanner {

    /// A materialised routine session for one day.
    struct Session: Equatable, Sendable {
        var routine: Routine
        var day: Date
        /// Minutes-since-midnight start, or nil for a flexible session with no fixed time.
        var startMinute: Int?
        var durationMinutes: Int

        /// Fixed sessions have a set time and anchor the day; flexible ones float and reflow.
        var isFixed: Bool { startMinute != nil }
    }

    // MARK: Fixed routines

    /// The fixed routines that meet on `day`, minus cancellations. Sorted by start time.
    static func fixedSessions(
        routines: [Routine],
        exceptions: [RoutineException],
        on day: Date,
        calendar: Calendar = .current
    ) -> [Session] {
        let weekday = calendar.component(.weekday, from: day)
        let dayKey = RoutineException.dayKey(day, calendar: calendar)
        let cancelled = Set(exceptions.filter { $0.date == dayKey }.map(\.routineId))

        return routines
            .filter { $0.active && $0.routineKind == .fixed }
            .filter { $0.weekdayNumbers.contains(weekday) }
            .filter { !cancelled.contains($0.id) }
            .map { Session(routine: $0, day: day, startMinute: $0.startMinute,
                           durationMinutes: $0.durationMinutes) }
            .sorted { ($0.startMinute ?? 0) < ($1.startMinute ?? 0) }
    }

    // MARK: Flexible routines

    /// Which days of `week` a flexible routine should run, given how busy each day already is.
    ///
    /// Picks the `timesPerWeek` (up to +flex) lightest days from those still eligible — today
    /// and the future, never the past — and, among equally-light days, spreads them out so you
    /// don't end up training four days straight. Days already completed this week count toward
    /// the target, so re-running mid-week doesn't over-schedule.
    static func flexibleDays(
        routine: Routine,
        week: [Date],
        busynessByDay: [Date: Int],
        completedDays: Set<Date>,
        now: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        let target = min(7, routine.timesPerWeek + routine.flex)
        guard target > 0 else { return [] }

        let today = calendar.startOfDay(for: now)
        let done = completedDays.map { calendar.startOfDay(for: $0) }
        let doneSet = Set(done)

        // Eligible = today or later, and not already done.
        let eligible = week
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 >= today && !doneSet.contains($0) }

        let remaining = max(0, target - doneSet.count)
        guard remaining > 0, !eligible.isEmpty else { return [] }

        // Rank by (lightest first, then earliest) and take what's left of the target.
        let ranked = eligible.sorted { a, b in
            let ba = busynessByDay[a] ?? 0, bb = busynessByDay[b] ?? 0
            if ba != bb { return ba < bb }
            return a < b
        }
        let chosen = Array(ranked.prefix(remaining))

        // Return in date order for a stable, readable result.
        return chosen.sorted()
    }

    /// A day's busyness score — the raw material for choosing rest days. Fixed routine minutes
    /// plus event minutes plus a light weight per scheduled task. Higher = leave it alone.
    static func busyness(
        day: Date,
        fixedRoutines: [Routine],
        exceptions: [RoutineException],
        events: [CalendarEvent],
        tasks: [TaskItem],
        calendar: Calendar = .current
    ) -> Int {
        var score = 0
        for session in fixedSessions(routines: fixedRoutines, exceptions: exceptions, on: day, calendar: calendar) {
            score += session.durationMinutes
        }
        for event in events where !event.isAllDay && calendar.isDate(event.start, inSameDayAs: day) {
            score += event.durationMinutes
        }
        for task in tasks where task.status != "completed" && !task.deleted {
            if let due = DueDate.parse(task.dueDate), calendar.isDate(due, inSameDayAs: day) {
                score += task.effortMinutes ?? 20
            }
        }
        return score
    }

    /// The seven days of the week containing `date`, starting on the calendar's first weekday.
    static func week(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
