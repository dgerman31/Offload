import Foundation

/// Auto-fit (feature C): when you capture a loose task with no time of its own, the app quietly
/// finds it a slot in today's open time instead of dropping it on an undated pile. Decisions
/// (locked 2026-07-21): **silent & movable** — placements are soft and unpinned, so the timeline
/// can still reflow them; **keep it today** — a task that doesn't fit still lands on today (as a
/// whole-day intention) rather than spilling to another day. A capture that stated its own time
/// is never touched.
enum AutoFit {

    /// Return `new` with any standalone, undated, top-level task given a soft "today" time fitted
    /// around today's existing work. Subtasks and project tasks are left alone — they aren't
    /// loose day-of items. Pure, so it's unit-tested; the caller persists the result.
    static func fitIntoToday(
        new: [TaskItem],
        existing: [TaskItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TaskItem] {
        let targetIDs = Set(new.filter { isLoose($0) }.map(\.id))
        guard !targetIDs.isEmpty else { return new }

        let today = calendar.startOfDay(for: now)
        // Existing timed work today acts as busy time so we don't double-book; the new loose
        // tasks are what the planner actually places.
        let existingToday = existing.filter { task in
            DueDate.parse(task.dueDate).map { calendar.isDate($0, inSameDayAs: now) } ?? false
        }
        let pool = existingToday + new.filter { targetIDs.contains($0.id) }
        let plan = DayPlanner.plan(tasks: pool, events: [], on: today, now: now, calendar: calendar)
        let placedStart = Dictionary(
            plan.scheduled.map { ($0.task.id, $0.start) }, uniquingKeysWith: { a, _ in a }
        )

        return new.map { task in
            guard targetIDs.contains(task.id) else { return task }
            var t = task
            if let start = placedStart[task.id] {
                t.dueDate = DueDate.canonicalString(from: start)   // soft timed slot
                t.dueIsAllDay = false
            } else {
                t.dueDate = DueDate.canonicalString(from: today)   // didn't fit → still today, all-day
                t.dueIsAllDay = true
            }
            t.pinned = false             // movable: the user never asked for this exact time
            t.dueDateConfidence = 0.5
            return t
        }
    }

    /// A loose day-of candidate: no date of its own, not completed, and not a subtask or a piece
    /// of a longer-running project (those belong to their parent, not to today).
    private static func isLoose(_ task: TaskItem) -> Bool {
        task.dueDate == nil
            && task.status != "completed"
            && !task.deleted
            && task.parentTaskId == nil
            && task.projectId == nil
    }
}
