import Foundation

/// Auto-fit (feature C): a freshly captured task that doesn't name its own clock time gets
/// quietly slotted into today's open time, so new entries land *on the schedule* instead of a
/// vague pile. Decisions (locked 2026-07-21): **silent & movable** — placements are soft and
/// unpinned so the timeline can still reflow them; **keep it today** — a task that finds no gap
/// still stays on today (as a whole-day intention). A capture that stated a real time is never
/// moved.
enum AutoFit {

    /// Return `new` with each plannable task given a soft time in the open slots of whichever day
    /// it should land on, scheduling around that day's already-committed work. "Plannable" is
    /// broader than "undated": a task the model stamped for *today* without a real clock time
    /// (all-day, or an unpinned guess) also gets a proper slot — that's the common case, since
    /// the model sets a due date for most captures. Pure, so it's unit-tested; the caller
    /// persists the result.
    ///
    /// `cutoffHour` is the user's "my day ends at" preference (Settings → Scheduling, the same
    /// value `DayPlanner`'s waking window and "Plan my day" use — one clock, not two). Past it,
    /// there's no realistic "later today" left to search: rather than hunt a closed window and
    /// fall back to dumping the task on today anyway (the original bug — every capture after
    /// that hour landed in "Anytime" no matter what), the whole search moves to tomorrow instead.
    static func fitIntoToday(
        new: [TaskItem],
        existing: [TaskItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        cutoffHour: Int = DayPlanner.defaultDayEndHour
    ) -> [TaskItem] {
        let targets = new.filter { needsPlanning($0, now: now, calendar: calendar) }
        guard !targets.isEmpty else { return new }

        let pastCutoff = calendar.component(.hour, from: now) >= cutoffHour
        let planningDay = pastCutoff
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            : calendar.startOfDay(for: now)
        // A fresh day tomorrow has nothing yet to skip past; today, the search still starts now.
        let searchFrom = pastCutoff ? planningDay : now

        // Everything already holding a real clock time on the planning day is busy time we
        // schedule around — existing tasks and (implicitly, since they aren't passed here)
        // events elsewhere.
        let busy: [CalendarEvent] = existing.compactMap { task in
            guard task.status != "completed", !task.deleted, !task.dueIsAllDay,
                  let start = DueDate.parse(task.dueDate),
                  calendar.isDate(start, inSameDayAs: planningDay) else { return nil }
            let minutes = task.effortMinutes ?? 30
            let end = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
            return CalendarEvent(id: task.id, title: task.title, start: start, end: end,
                                 isAllDay: false, location: nil, colorHex: nil)
        }

        let slots = DayPlanner.freeSlots(events: busy, on: planningDay, now: searchFrom,
                                          calendar: calendar, dayEndHour: cutoffHour)
        var cursors = slots.map(\.start)
        var placed: [String: Date] = [:]

        // Greedy earliest-fit — most-pressing first — without the day-planner's "stop at 67%
        // full" throttle: the user asked for the new thing to land on the day, so it does.
        for task in targets.sorted(by: morePressing) {
            let effort = task.effortMinutes ?? 30
            for index in slots.indices {
                let start = cursors[index]
                guard let end = calendar.date(byAdding: .minute, value: effort, to: start),
                      end <= slots[index].end else { continue }
                placed[task.id] = start
                // `slots` already start on a quarter-hour (`DayPlanner.freeSlots` rounds them),
                // but each subsequent placement within the same slot needs the same rounding
                // applied again here, so every task lands on a clean 15-minute mark, not
                // wherever the previous one's effort+buffer happened to sum to.
                let afterBuffer = calendar.date(byAdding: .minute, value: effort + 5, to: start) ?? slots[index].end
                cursors[index] = DayPlanner.roundUpToQuarterHour(afterBuffer, calendar: calendar)
                break
            }
        }

        let targetIDs = Set(targets.map(\.id))
        return new.map { task in
            guard targetIDs.contains(task.id) else { return task }
            var t = task
            if let start = placed[task.id] {
                t.dueDate = DueDate.canonicalString(from: start)   // soft timed slot
                t.dueIsAllDay = false
            } else {
                t.dueDate = DueDate.canonicalString(from: planningDay)   // no gap → whole-day intention
                t.dueIsAllDay = true
            }
            t.pinned = false             // movable: the user never asked for this exact time
            t.dueDateConfidence = 0.5
            return t
        }
    }

    /// A task that should be fitted into today: standalone (not a subtask or project piece), open,
    /// and either undated or set for today without a committed clock time. Anything pinned, tied
    /// to a real event, or dated for another day is left exactly where it is.
    private static func needsPlanning(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        guard task.status != "completed", !task.deleted,
              task.parentTaskId == nil, task.projectId == nil else { return false }
        guard let due = DueDate.parse(task.dueDate) else { return true }   // undated → plan for today
        guard calendar.isDate(due, inSameDayAs: now) else { return false } // another day → leave it
        // Due today: plan it unless it's a fixed commitment (pinned time or real event).
        return !task.isAnchored && (task.dueIsAllDay || !task.pinned)
    }

    /// High priority first, then shorter tasks — quick wins slot ahead of long ones.
    private static func morePressing(_ a: TaskItem, _ b: TaskItem) -> Bool {
        func rank(_ p: String) -> Int { p == "high" ? 0 : (p == "low" ? 2 : 1) }
        let (ra, rb) = (rank(a.priority), rank(b.priority))
        if ra != rb { return ra < rb }
        return (a.effortMinutes ?? 30) < (b.effortMinutes ?? 30)
    }
}
