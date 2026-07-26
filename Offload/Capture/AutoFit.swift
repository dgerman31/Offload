import Foundation

/// Auto-fit (feature C): a freshly captured task that doesn't name its own clock time gets
/// quietly slotted into today's open time, so new entries land *on the schedule* instead of a
/// vague pile. Decisions (locked 2026-07-21): **silent & movable** — placements are soft and
/// unpinned so the timeline can still reflow them; **always a real time** — a task that finds no
/// gap today rolls to the next day that has one rather than becoming a whole-day "Anytime"
/// intention (revised 2026-07-25). A capture that stated a real time is never moved.
enum AutoFit {

    /// How many days forward the search will roll before giving up. A capture is supposed to land
    /// on a real clock time, so a full day pushes the leftovers to the next day rather than
    /// dropping them into "Anytime" — which is what happened whenever a day had no gap big enough,
    /// and is the outcome the user explicitly doesn't want.
    static let maxDaysAhead = 14

    /// Return `new` with each plannable task given a soft time in the open slots of whichever day
    /// it should land on, scheduling around that day's already-committed work. "Plannable" is
    /// broader than "undated": a task the model stamped for *today* without a real clock time
    /// (all-day, or an unpinned guess) also gets a proper slot — that's the common case, since
    /// the model sets a due date for most captures. Pure, so it's unit-tested; the caller
    /// persists the result.
    ///
    /// `cutoffHour` is the user's "my day ends at" preference (Settings → Scheduling, the same
    /// value `DayPlanner`'s waking window and "Plan my day" use — one clock, not two). Past it,
    /// there's no realistic "later today" left to search, so the search starts tomorrow instead.
    ///
    /// Anything that doesn't fit the day being searched carries over to the next one, up to
    /// `maxDaysAhead`. A single task longer than every remaining gap used to end up as a whole-day
    /// "Anytime" intention; now it just gets tomorrow morning.
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
        let firstDay = pastCutoff
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            : calendar.startOfDay(for: now)

        var placed: [String: Date] = [:]
        // Most-pressing first, and whatever doesn't fit today carries over to the next day in the
        // same order rather than being dropped.
        var remaining = targets.sorted(by: morePressing)
        var day = firstDay
        var daysSearched = 0

        while !remaining.isEmpty, daysSearched < maxDaysAhead {
            // A fresh future day has nothing yet to skip past; today, the search still starts now.
            let searchFrom = calendar.isDate(day, inSameDayAs: now) ? now : day
            let slots = DayPlanner.freeSlots(events: busyBlocks(existing, on: day, calendar: calendar),
                                             on: day, now: searchFrom,
                                             calendar: calendar, dayEndHour: cutoffHour)
            var cursors = slots.map(\.start)
            var didNotFit: [TaskItem] = []

            // Greedy earliest-fit, without the day-planner's "stop at 67% full" throttle: the
            // user asked for the new thing to land on the schedule, so it does.
            for task in remaining {
                let effort = task.effortMinutes ?? 30
                var fitted = false
                for index in slots.indices {
                    let start = cursors[index]
                    guard let end = calendar.date(byAdding: .minute, value: effort, to: start),
                          end <= slots[index].end else { continue }
                    placed[task.id] = start
                    // `slots` already start on a quarter-hour (`DayPlanner.freeSlots` rounds
                    // them), but each subsequent placement within the same slot needs the same
                    // rounding applied again here, so every task lands on a clean 15-minute mark,
                    // not wherever the previous one's effort+buffer happened to sum to.
                    let afterBuffer = calendar.date(byAdding: .minute, value: effort + 5, to: start) ?? slots[index].end
                    cursors[index] = DayPlanner.roundUpToQuarterHour(afterBuffer, calendar: calendar)
                    fitted = true
                    break
                }
                if !fitted { didNotFit.append(task) }
            }

            remaining = didNotFit
            daysSearched += 1
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }

        let targetIDs = Set(targets.map(\.id))
        return new.map { task in
            guard targetIDs.contains(task.id) else { return task }
            var t = task
            if let start = placed[task.id] {
                t.dueDate = DueDate.canonicalString(from: start)   // soft timed slot
                t.dueIsAllDay = false
            } else {
                // Only reachable if two solid weeks are genuinely full end to end. Keeping it as
                // a whole-day intention on the first day beats inventing a time inside work
                // that's already committed.
                t.dueDate = DueDate.canonicalString(from: firstDay)
                t.dueIsAllDay = true
            }
            t.pinned = false             // movable: the user never asked for this exact time
            t.dueDateConfidence = 0.5
            return t
        }
    }

    /// Everything already holding a real clock time on `day` — busy time to schedule around.
    /// Existing tasks only; real calendar events aren't passed to this function.
    private static func busyBlocks(_ existing: [TaskItem], on day: Date, calendar: Calendar) -> [CalendarEvent] {
        existing.compactMap { task in
            guard task.status != "completed", !task.deleted, !task.dueIsAllDay,
                  let start = DueDate.parse(task.dueDate),
                  calendar.isDate(start, inSameDayAs: day) else { return nil }
            let minutes = task.effortMinutes ?? 30
            let end = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
            return CalendarEvent(id: task.id, title: task.title, start: start, end: end,
                                 isAllDay: false, location: nil, colorHex: nil)
        }
    }

    /// A task that should be fitted into the schedule: a real top-level task, open, and either
    /// undated or set for today without a committed clock time. Anything pinned, tied to a real
    /// event, or dated for another day is left exactly where it is.
    ///
    /// A *step* is still skipped — it belongs to its parent task and gets done as part of it, so
    /// scheduling each one its own slot would shred a single piece of work across the day. A
    /// task that belongs to a **project** is not skipped, though: it's a real piece of work the
    /// user expects on the schedule like any other, and skipping it was a way for captures to
    /// quietly land in "Anytime" — which matters more now that a capture actually creates
    /// projects, since without this every task in a new project would go unscheduled.
    private static func needsPlanning(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        guard task.status != "completed", !task.deleted,
              task.parentTaskId == nil else { return false }
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
