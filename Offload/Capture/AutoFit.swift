import Foundation

/// Auto-fit (feature C): a freshly captured task that doesn't name its own clock time gets
/// quietly slotted into open time, so new entries land *on the schedule* instead of a vague pile.
/// Decisions (locked 2026-07-21): **silent & movable** — placements are soft and unpinned so the
/// timeline can still reflow them; **always a real time** — a task that finds no gap on its own
/// day rolls forward to the next day that has one rather than becoming a whole-day "Anytime"
/// intention (revised 2026-07-25). A capture that stated a real time is never moved.
///
/// Two rules earn their own paragraph, because getting them wrong is exactly what the user
/// reported:
///
/// 1. **Every capture gets a real time on the day it belongs to** — not only today's. A task the
///    model dated for Thursday as a whole-day intention is planned into *Thursday's* free time
///    rather than sitting in "Anytime", which is what the old today-only rule left it doing. The
///    single exception is work that already names its own moment: a stated clock time, or an
///    anchor (pinned by hand, or backed by a real calendar event), is left completely alone.
/// 2. **Nothing is ever placed on top of anything.** The busy set is every task holding a real
///    time on that day — from `existing` *and* from the very same capture — plus everything this
///    call has itself already placed. A capture saying "lecture at 11, and I need to read the
///    chapter" used to schedule the reading straight through the lecture, because the lecture (a
///    sibling in the same batch, not yet in the database) was invisible to the placement loop.
enum AutoFit {

    /// How many days forward the search rolls before it stops looking for genuine free time.
    /// A capture is supposed to land on a real clock time, so a full day pushes its leftovers to
    /// the next day rather than dropping them into "Anytime".
    static let maxDaysAhead = 14

    /// What a task with no estimate is assumed to take — used both when placing it and when
    /// treating it as busy time, so the two always agree.
    static let defaultEffortMinutes = 30

    /// Return `new` with each plannable task given a soft time in the open slots of whichever day
    /// it should land on, scheduling around that day's already-committed work.
    ///
    /// "Plannable" is broader than "undated": a task the model stamped for a *day* without a real
    /// clock time (all-day, or a whole-day guess) also gets a proper slot — that's the common
    /// case, since the model sets a due date for most captures. The day it gets is its own: today
    /// for undated work, Thursday for something stamped Thursday. Pure, so it's unit-tested; the
    /// caller persists the result.
    ///
    /// `cutoffHour` is the user's "my day ends at" preference (Settings → Scheduling, the same
    /// value `DayPlanner`'s waking window and "Plan my day" use — one clock, not two). Past it
    /// there's no realistic "later today" left to search, so nothing is placed before tomorrow.
    ///
    /// Anything that doesn't fit the day being searched carries over to the next one, up to
    /// `maxDaysAhead`; a task that somehow fits nowhere in all that time still comes back with
    /// the earliest open moment on its own day rather than a whole-day "Anytime" intention.
    /// `startHour` is the other half of the same preference — "my day starts at". It used to be
    /// absent, so every search here ran against `DayPlanner.defaultDayStartHour` (9am) no matter
    /// what the user had set: someone whose day begins at 6 got nothing placed before 9, and three
    /// hours of their morning were invisible to auto-fit.
    ///
    /// `protected` is the week's reserved time — study, gym, meals. Empty by default so the pure
    /// tests stay pure; real call sites pass `ProtectedTime.stored()`.
    static func fitIntoToday(
        new: [TaskItem],
        existing: [TaskItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        startHour: Int = DayPlanner.defaultDayStartHour,
        cutoffHour: Int = DayPlanner.defaultDayEndHour,
        protected: [ProtectedBlock] = []
    ) -> [TaskItem] {
        let targets = new.filter { needsPlanning($0) }
        guard !targets.isEmpty else { return new }
        let targetIDs = Set(targets.map(\.id))

        let today = calendar.startOfDay(for: now)
        let pastCutoff = calendar.component(.hour, from: now) >= cutoffHour
        // Past the cutoff there's no usable "later today" left, so the earliest day anything may
        // be placed on is tomorrow.
        let firstDay = pastCutoff
            ? (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
            : today

        // Busy time to schedule around: everything already holding a real clock time. Crucially
        // that includes the members of *this* capture that stated their own time — they aren't
        // targets (nothing moves them), but they are real commitments, and leaving them out is
        // how an untimed sibling ended up sitting on top of one.
        var blocked = busyBlocks(existing + new.filter { !targetIDs.contains($0.id) },
                                 calendar: calendar)
        var placed: [String: Date] = [:]

        // Every placement immediately joins the busy set, so the second task of a capture is
        // planned around the first — including on a day this same call already put work on.
        func commit(_ task: TaskItem, at start: Date) {
            placed[task.id] = start
            let end = calendar.date(byAdding: .minute, value: effort(of: task), to: start) ?? start
            blocked.append(CalendarEvent(id: "autofit-\(task.id)", title: task.title,
                                         start: start, end: end, isAllDay: false,
                                         location: nil, colorHex: nil))
        }

        // Each target belongs to a day of its own. Earliest day first, so work rolling forward
        // out of a full Monday is placed before Tuesday's own captures claim Tuesday's gaps.
        let byDay = Dictionary(grouping: targets) {
            targetDay(for: $0, firstDay: firstDay, calendar: calendar)
        }

        for startDay in byDay.keys.sorted() {
            // Most-pressing first, and whatever doesn't fit carries over to the next day in the
            // same order rather than being dropped.
            var remaining = (byDay[startDay] ?? []).sorted(by: morePressing)
            var day = startDay
            var daysSearched = 0

            while !remaining.isEmpty, daysSearched < maxDaysAhead {
                // Protected time is expanded per day, since which blocks apply depends on the
                // weekday — Tuesday's gym hour isn't Wednesday's.
                let dayBlocked = blocked + ProtectedTime.busyBlocks(on: day, blocks: protected,
                                                                    calendar: calendar)
                let outcome = fill(day: day, with: remaining, now: now, calendar: calendar,
                                   startHour: startHour, cutoffHour: cutoffHour, blocked: dayBlocked)
                for placement in outcome.placed { commit(placement.task, at: placement.start) }
                remaining = outcome.didNotFit
                daysSearched += 1
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }

            // Two solid weeks with no gap big enough. "Anytime" is the one outcome the user
            // explicitly doesn't want, so take the earliest open moment on the day this task
            // belongs to instead — a real time they can drag beats no time at all.
            for task in remaining {
                let start = earliestOpenMoment(
                    on: startDay, now: now, calendar: calendar,
                    startHour: startHour, cutoffHour: cutoffHour,
                    blocked: blocked + ProtectedTime.busyBlocks(on: startDay, blocks: protected,
                                                               calendar: calendar))
                commit(task, at: start)
            }
        }

        return new.map { task in
            // Every target gets placed now, so there's no whole-day fallback left; the guard only
            // exists so an unplaceable task comes back untouched rather than mangled.
            guard targetIDs.contains(task.id), let start = placed[task.id] else { return task }
            var t = task
            t.dueDate = DueDate.canonicalString(from: start)   // soft timed slot
            t.dueIsAllDay = false
            t.pinned = false             // movable: the user never asked for this exact time
            t.dueDateConfidence = 0.5
            return t
        }
    }

    /// Greedy earliest-fit into one day's free slots, without the day-planner's "stop at 67%
    /// full" throttle: the user asked for the new thing to land on the schedule, so it does.
    /// Returns what fit and what has to try tomorrow. Nothing here mutates `blocked` — placements
    /// within a single day are kept apart by the per-slot cursors, and the caller folds them into
    /// the busy set for every later day.
    private static func fill(
        day: Date,
        with tasks: [TaskItem],
        now: Date,
        calendar: Calendar,
        startHour: Int,
        cutoffHour: Int,
        blocked: [CalendarEvent]
    ) -> (placed: [(task: TaskItem, start: Date)], didNotFit: [TaskItem]) {
        // A future day has nothing yet to skip past; today, the search still starts now.
        let searchFrom = calendar.isDate(day, inSameDayAs: now) ? now : day
        let slots = DayPlanner.freeSlots(events: blocked, on: day, now: searchFrom,
                                         calendar: calendar, dayStartHour: startHour,
                                         dayEndHour: cutoffHour)
        var cursors = slots.map(\.start)
        var placed: [(task: TaskItem, start: Date)] = []
        var didNotFit: [TaskItem] = []

        for task in tasks {
            let minutes = effort(of: task)
            var fitted = false
            for index in slots.indices {
                let start = cursors[index]
                guard let end = calendar.date(byAdding: .minute, value: minutes, to: start),
                      end <= slots[index].end else { continue }
                placed.append((task: task, start: start))
                // `slots` already start on a quarter-hour (`DayPlanner.freeSlots` rounds them),
                // but each subsequent placement within the same slot needs the same rounding
                // applied again here, so every task lands on a clean 15-minute mark, not wherever
                // the previous one's effort+buffer happened to sum to.
                let afterBuffer = calendar.date(byAdding: .minute,
                                                value: minutes + DayPlanner.bufferMinutes,
                                                to: start) ?? slots[index].end
                cursors[index] = DayPlanner.roundUpToQuarterHour(afterBuffer, calendar: calendar)
                fitted = true
                break
            }
            if !fitted { didNotFit.append(task) }
        }
        return (placed: placed, didNotFit: didNotFit)
    }

    /// The first moment on `day` that isn't already spoken for — the last-resort placement for a
    /// task that found no real gap anywhere. Normally that's simply the start of the day's first
    /// free slot; on a day with no usable gap at all it steps past whatever is booked and takes
    /// the next quarter-hour, so even the compressed fallback never double-books.
    private static func earliestOpenMoment(
        on day: Date,
        now: Date,
        calendar: Calendar,
        startHour: Int,
        cutoffHour: Int,
        blocked: [CalendarEvent]
    ) -> Date {
        let searchFrom = calendar.isDate(day, inSameDayAs: now) ? now : day
        if let first = DayPlanner.freeSlots(events: blocked, on: day, now: searchFrom,
                                            calendar: calendar, dayStartHour: startHour,
                                            dayEndHour: cutoffHour).first {
            return first.start
        }

        let windowStart = calendar.date(bySettingHour: startHour,
                                        minute: 0, second: 0, of: day) ?? day
        let earliest = calendar.isDate(day, inSameDayAs: now) ? max(windowStart, now) : windowStart
        var candidate = DayPlanner.roundUpToQuarterHour(earliest, calendar: calendar)
        // One ascending pass is enough: any block that could still contain the candidate starts
        // no earlier than the block that just pushed it.
        let sameDay = blocked
            .filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
        for block in sameDay where block.start <= candidate && block.end > candidate {
            candidate = DayPlanner.roundUpToQuarterHour(block.end, calendar: calendar)
        }
        return candidate
    }

    /// The day a target belongs on: the day it was stamped for, or today when it's undated —
    /// never earlier than the first day the search may use, so overdue captures and anything
    /// caught after the day's cutoff move forward instead of into the past.
    private static func targetDay(for task: TaskItem, firstDay: Date, calendar: Calendar) -> Date {
        guard let due = DueDate.parse(task.dueDate) else { return firstDay }
        return max(calendar.startOfDay(for: due), firstDay)
    }

    /// Everything holding a real clock time — busy time to schedule around. Deliberately *not*
    /// filtered by day: `DayPlanner.freeSlots` already keeps only the blocks belonging to the day
    /// it's computing, so one pass serves every day the search visits. Real calendar events
    /// aren't passed to this function.
    private static func busyBlocks(_ tasks: [TaskItem], calendar: Calendar) -> [CalendarEvent] {
        tasks.compactMap { task in
            guard task.status != "completed", !task.deleted, !task.dueIsAllDay,
                  let start = DueDate.parse(task.dueDate) else { return nil }
            let end = calendar.date(byAdding: .minute, value: effort(of: task), to: start) ?? start
            return CalendarEvent(id: task.id, title: task.title, start: start, end: end,
                                 isAllDay: false, location: nil, colorHex: nil)
        }
    }

    /// A task that should be fitted into the schedule: a real top-level task, open, and without a
    /// moment of its own yet — undated, or stamped for a day as a whole-day intention.
    ///
    /// What is *never* touched: a task carrying a real, stated clock time ("meet Sarah at 3" — the
    /// capture pipeline pins those, and the pin isn't the only reason to respect them), and
    /// anything anchored to a pinned time or a real calendar event.
    ///
    /// A *step* is still skipped — it belongs to its parent task and gets done as part of it, so
    /// scheduling each one its own slot would shred a single piece of work across the day. A task
    /// that belongs to a **project** is not skipped, though: it's a real piece of work the user
    /// expects on the schedule like any other, and skipping it was a way for captures to quietly
    /// land in "Anytime" — which matters more now that a capture actually creates projects.
    ///
    /// Note what's deliberately absent: any test against *today*. The old rule bailed out on
    /// anything dated for another day, which is precisely why a capture the model dated for
    /// tomorrow never got a clock time and showed up under "Anytime". A whole-day intention is
    /// planned into its own day's free time, whichever day that is.
    private static func needsPlanning(_ task: TaskItem) -> Bool {
        // `isPlannable` first, and it matters most here: this is the path that places *undated*
        // captures into today automatically, so without it every idea you ever spoke would be
        // given a slot in this afternoon within seconds of saying it.
        guard task.isPlannable, task.parentTaskId == nil else { return false }
        guard DueDate.parse(task.dueDate) != nil else { return true }   // undated → plan it today
        guard !task.isAnchored else { return false }                    // fixed commitment → leave it
        return task.dueIsAllDay                                         // a real time → leave it
    }

    /// How long a task is assumed to occupy, whether it's being placed or being scheduled around.
    private static func effort(of task: TaskItem) -> Int {
        task.effortMinutes ?? defaultEffortMinutes
    }

    /// High priority first, then shorter tasks — quick wins slot ahead of long ones.
    private static func morePressing(_ a: TaskItem, _ b: TaskItem) -> Bool {
        func rank(_ p: String) -> Int { p == "high" ? 0 : (p == "low" ? 2 : 1) }
        let (ra, rb) = (rank(a.priority), rank(b.priority))
        if ra != rb { return ra < rb }
        return effort(of: a) < effort(of: b)
    }
}
