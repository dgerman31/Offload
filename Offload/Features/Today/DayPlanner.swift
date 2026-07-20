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

    /// Which tasks are candidates for today: open, not deleted, and either due today, overdue,
    /// or undated (the "whenever" pile is exactly what a plan is for). Ordered most-pressing
    /// first — overdue, then priority, then shortest, so early wins build momentum.
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
            .filter { $0.status != "completed" && !$0.deleted }
            .filter { task in
                guard let due = DueDate.parse(task.dueDate) else { return true }   // undated
                return due < startOfDay || calendar.isDate(due, inSameDayAs: day)  // overdue or today
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
        limit: Int = 12
    ) -> Plan {
        let slots = freeSlots(events: events, on: day, now: now, calendar: calendar,
                              dayStartHour: dayStartHour, dayEndHour: dayEndHour)
        let ordered = Array(candidates(from: tasks, on: day, now: now, calendar: calendar).prefix(limit))

        var result = Plan()
        result.freeMinutes = slots.reduce(0) { $0 + $1.minutes }
        guard !slots.isEmpty else {
            result.unplaced = ordered
            return result
        }

        // Track how far into each slot we've filled.
        var cursors = slots.map(\.start)

        for task in ordered {
            let effort = task.effortMinutes ?? EnergyBatch.defaultEffort
            var placed = false

            for index in slots.indices {
                let slotEnd = slots[index].end
                let start = cursors[index]
                guard let end = calendar.date(byAdding: .minute, value: effort, to: start), end <= slotEnd else { continue }

                result.scheduled.append(ScheduledTask(task: task, start: start, end: end))
                cursors[index] = calendar.date(byAdding: .minute, value: bufferMinutes, to: end) ?? end
                placed = true
                break
            }
            if !placed { result.unplaced.append(task) }
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
