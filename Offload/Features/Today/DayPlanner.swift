import Foundation

/// Turns a pile of tasks into an actual plan for the day.
///
/// The app already knew *what* you had to do and *when you were busy* — but never put the two
/// together. This finds the real gaps between your calendar events, then fits work into them
/// by priority and effort, so "organize my day" produces times you could actually keep rather
/// than another ranked list.
///
/// Entirely deterministic and pure, so the arithmetic is unit-tested; the on-device model is
/// only used to narrate the result, never to compute it.
enum DayPlanner {

    /// Waking window — when the planner is allowed to schedule work.
    static let dayStartHourKey = "offload.planner.dayStartHour"
    static let dayEndHourKey = "offload.planner.dayEndHour"
    static let defaultDayStartHour = 9
    static let defaultDayEndHour = 21

    /// Breathing room between scheduled tasks; back-to-back plans never survive contact.
    static let bufferMinutes = 5
    /// Gaps shorter than this aren't worth planning into.
    static let minimumSlotMinutes = 10
    /// Fill about two thirds of free time. Planning to 100% is the classic time-blocking
    /// failure — the first interruption invalidates the whole day.
    static let planningRatio = 0.67

    struct FreeSlot: Identifiable, Sendable, Equatable {
        var start: Date
        var end: Date
        var id: Double { start.timeIntervalSince1970 }
        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    }

    struct ScheduledTask: Identifiable, Sendable, Equatable {
        var task: TaskItem
        var start: Date
        var end: Date
        var id: String { task.id }
        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    }

    struct Plan: Sendable, Equatable {
        var scheduled: [ScheduledTask] = []
        /// Tasks that didn't fit — surfaced honestly rather than silently dropped.
        var unplaced: [TaskItem] = []
        var freeMinutes = 0

        var isEmpty: Bool { scheduled.isEmpty && unplaced.isEmpty }
    }

    // MARK: Free time

    /// The open stretches of a day: the waking window minus calendar events, never starting
    /// in the past. All-day events don't block time — they're context, not commitments.
    static func freeSlots(
        events: [CalendarEvent],
        on day: Date,
        now: Date,
        calendar: Calendar = .current,
        dayStartHour: Int = defaultDayStartHour,
        dayEndHour: Int = defaultDayEndHour
    ) -> [FreeSlot] {
        guard let windowStart = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: day),
              let windowEnd = calendar.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: day),
              windowEnd > windowStart
        else { return [] }

        // Planning today starts now, not this morning.
        let effectiveStart = calendar.isDate(day, inSameDayAs: now) ? max(windowStart, now) : windowStart
        guard effectiveStart < windowEnd else { return [] }

        // Busy intervals for this day, clipped to the window and merged.
        let busy = events
            .filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: day) }
            .map { (start: max($0.start, effectiveStart), end: min($0.end, windowEnd)) }
            .filter { $0.start < $0.end }
            .sorted { $0.start < $1.start }

        var merged: [(start: Date, end: Date)] = []
        for interval in busy {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        var slots: [FreeSlot] = []
        var cursor = effectiveStart
        for interval in merged {
            if interval.start > cursor {
                slots.append(FreeSlot(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < windowEnd {
            slots.append(FreeSlot(start: cursor, end: windowEnd))
        }
        return slots.filter { $0.minutes >= minimumSlotMinutes }
    }

    // MARK: Planning

    /// Tasks the user already committed to a specific time today. These are NOT candidates —
    /// they're constraints. Moving someone's 1pm lunch to 9am because it happened to be
    /// "unscheduled work due today" is exactly the wrong behaviour: fixed commitments get
    /// blocked out first, and flexible work fills in around them.
    static func fixedCommitments(from tasks: [TaskItem], on day: Date, calendar: Calendar = .current) -> [TaskItem] {
        tasks.filter { task in
            // Only *anchored* times are constraints. A soft planner-placed time is re-placeable,
            // so re-planning reflows it rather than building around a guess.
            guard task.status != "completed", !task.deleted, task.isAnchored,
                  let due = DueDate.parse(task.dueDate) else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
    }

    /// Turn fixed commitments into busy blocks so free time is computed around them, exactly
    /// like calendar events.
    static func busyBlocks(from tasks: [TaskItem], on day: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        fixedCommitments(from: tasks, on: day, calendar: calendar).compactMap { task in
            guard let start = DueDate.parse(task.dueDate) else { return nil }
            let minutes = task.effortMinutes ?? EnergyBatch.defaultEffort
            let end = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
            return CalendarEvent(id: "task-\(task.id)", title: task.title, start: start,
                                 end: end, isAllDay: false, location: nil, colorHex: nil)
        }
    }

    /// Which tasks are candidates for placing: open, not deleted, not blocked on someone else,
    /// and *flexible* — undated, whole-day, or overdue. Anything with a committed time is left
    /// exactly where the user put it. Ordered most-pressing first, so early wins build momentum.
    static func candidates(from tasks: [TaskItem], on day: Date, now: Date, calendar: Calendar = .current) -> [TaskItem] {
        func rank(_ p: String) -> Int {
            switch p {
            case "high": return 0
            case "low":  return 2
            default:     return 1
            }
        }
        let startOfDay = calendar.startOfDay(for: day)

        return tasks
            // "waiting" is blocked on someone else — scheduling time for it would be a lie.
            .filter { $0.status != "completed" && $0.status != "waiting" && !$0.deleted }
            .filter { task in
                guard let due = DueDate.parse(task.dueDate) else { return true }   // undated
                if due < startOfDay { return true }                                // overdue
                // Due today: movable unless it's an anchored commitment (pinned or a real
                // event). Soft planner-placed times are candidates again, so a re-plan reflows.
                return calendar.isDate(due, inSameDayAs: day) && !task.isAnchored
            }
            .sorted { a, b in
                let aOverdue = (DueDate.parse(a.dueDate).map { $0 < startOfDay }) ?? false
                let bOverdue = (DueDate.parse(b.dueDate).map { $0 < startOfDay }) ?? false
                if aOverdue != bOverdue { return aOverdue }
                let (ra, rb) = (rank(a.priority), rank(b.priority))
                if ra != rb { return ra < rb }
                let (ea, eb) = (a.effortMinutes ?? EnergyBatch.defaultEffort, b.effortMinutes ?? EnergyBatch.defaultEffort)
                if ea != eb { return ea < eb }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    /// Greedily place tasks into the day's free slots, most-pressing first, leaving a buffer
    /// between them. A task that fits nowhere is reported as unplaced rather than crammed in.
    static func plan(
        tasks: [TaskItem],
        events: [CalendarEvent],
        on day: Date,
        now: Date,
        calendar: Calendar = .current,
        dayStartHour: Int = defaultDayStartHour,
        dayEndHour: Int = defaultDayEndHour,
        limit: Int = 12,
        energyProfile: EnergyProfile? = nil,
        preferredOrder: [String]? = nil
    ) -> Plan {
        // Fixed commitments block time exactly like calendar events — the user's 1pm lunch is
        // as real as a meeting invite.
        let blocked = events + busyBlocks(from: tasks, on: day, calendar: calendar)
        let slots = freeSlots(events: blocked, on: day, now: now, calendar: calendar,
                              dayStartHour: dayStartHour, dayEndHour: dayEndHour)
        var pool = candidates(from: tasks, on: day, now: now, calendar: calendar)
        // A smart planner can hand us an order that weighs things the greedy sort can't —
        // deadlines, what pairs well, energy. Honour it; anything it didn't rank keeps its place.
        if let preferredOrder {
            let rank = Dictionary(preferredOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let ranked = pool.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
            let unranked = pool.filter { rank[$0.id] == nil }   // keeps its original order after the ranked
            pool = ranked + unranked
        }
        let ordered = Array(pool.prefix(limit))

        var result = Plan()
        result.freeMinutes = slots.reduce(0) { $0 + $1.minutes }

        // Plan roughly two thirds of what's free. A day packed to 100% survives contact with
        // reality for about an hour, and leaves no room for the things you didn't foresee.
        let plannableMinutes = Int(Double(result.freeMinutes) * planningRatio)
        var committedMinutes = 0
        guard !slots.isEmpty else {
            result.unplaced = ordered
            return result
        }

        // Track how far into each slot we've filled.
        var cursors = slots.map(\.start)

        for task in ordered {
            let effort = task.effortMinutes ?? EnergyBatch.defaultEffort

            // Stop once the day is reasonably full rather than cramming every free minute.
            if committedMinutes + effort > plannableMinutes, !result.scheduled.isEmpty {
                result.unplaced.append(task)
                continue
            }

            // Consider every slot that fits, then take the best one rather than merely the
            // first: with an energy profile set, demanding work gets your peak hours and
            // admin is nudged out of them. Ties break earliest, so the day still front-loads.
            var best: (index: Int, start: Date, end: Date, penalty: Int)?
            for index in slots.indices {
                let start = cursors[index]
                guard let end = calendar.date(byAdding: .minute, value: effort, to: start),
                      end <= slots[index].end else { continue }

                let penalty = energyProfile.map {
                    EnergyProfile.penalty(for: task, at: start, profile: $0, calendar: calendar)
                } ?? 0

                if let current = best {
                    if penalty < current.penalty { best = (index, start, end, penalty) }
                } else {
                    best = (index, start, end, penalty)
                }
            }

            if let best {
                result.scheduled.append(ScheduledTask(task: task, start: best.start, end: best.end))
                cursors[best.index] = calendar.date(byAdding: .minute, value: bufferMinutes, to: best.end) ?? best.end
                committedMinutes += effort
            } else {
                result.unplaced.append(task)
            }
        }

        result.scheduled.sort { $0.start < $1.start }
        return result
    }

    /// A short, honest summary of the plan for the sheet header.
    static func summary(for plan: Plan) -> String {
        if plan.scheduled.isEmpty {
            return plan.freeMinutes == 0
                ? "No open time left today — nothing to schedule into."
                : "Nothing to plan right now."
        }
        let count = plan.scheduled.count
        let minutes = plan.scheduled.reduce(0) { $0 + $1.minutes }
        var line = "\(count) task\(count == 1 ? "" : "s") · about \(formatted(minutes)) of work"
        if plan.unplaced.count > 0 {
            line += " · \(plan.unplaced.count) didn't fit"
        }
        return line
    }

    static func formatted(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
