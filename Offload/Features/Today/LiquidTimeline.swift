import Foundation

/// The self-healing timeline.
///
/// Most planners are brittle: place a task at 2pm, and if 2pm comes and goes it just rots into
/// an "Overdue" badge, and one overrun cascades the whole day into red. Offload's timeline is
/// liquid instead — soft-scheduled work (times the planner *guessed*) flows forward around the
/// day's fixed points as time passes, so the schedule always reflects reality rather than the
/// morning's optimism.
///
/// What never moves: real calendar events and *pinned* tasks (a time a human set). Those are
/// the banks the river flows between. Everything else reflows from "now" every time this runs.
///
/// Entirely pure and deterministic, so the reflow logic is unit-tested; the UI just renders it.
enum LiquidTimeline {

    /// A fixed point the flow must respect — an event or a pinned task.
    struct Anchor: Equatable, Sendable {
        var start: Date
        var end: Date
    }

    /// A soft task with its freshly-projected time.
    struct Placed: Identifiable, Equatable, Sendable {
        var task: TaskItem
        var start: Date
        var end: Date
        /// Where it originally sat, if it had a planned time.
        var plannedStart: Date?
        /// Minutes later than planned (>0 = the day has slipped and it moved back). 0 when it
        /// hasn't moved or was never scheduled to a time.
        var driftMinutes: Int
        var id: String { task.id }

        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
        var hasMoved: Bool { driftMinutes >= LiquidTimeline.driftThreshold }
    }

    struct Result: Equatable, Sendable {
        /// Soft tasks with projected times, chronological.
        var placed: [Placed] = []
        /// Tasks that no longer fit in what's left of the day.
        var spilled: [TaskItem] = []
        /// How far behind the day is running — the drift of the next thing you'd do.
        var behindMinutes: Int = 0

        /// True when reality has diverged from the plan enough to mention.
        var isHealing: Bool {
            behindMinutes >= LiquidTimeline.driftThreshold || !spilled.isEmpty
        }
    }

    /// Drift smaller than this isn't worth showing — a couple of minutes is noise.
    static let driftThreshold = 5
    /// Breathing room between reflowed tasks, matching the planner.
    static let bufferMinutes = 5

    /// Reflow `softTasks` into the time left today, around `anchors`, starting from `now`.
    ///
    /// - softTasks: today's flexible scheduled tasks that aren't done. Order is preserved by
    ///   their planned time (in-progress first, so the thing you're mid-way through stays put).
    /// - anchors: events and pinned tasks that must not move.
    static func heal(
        softTasks: [TaskItem],
        anchors: [Anchor],
        now: Date,
        calendar: Calendar = .current,
        dayEndHour: Int = DayPlanner.defaultDayEndHour
    ) -> Result {
        guard let windowEnd = endOfDay(now, hour: dayEndHour, calendar: calendar), windowEnd > now else {
            return Result(placed: [], spilled: softTasks.sortedForFlow(now: now), behindMinutes: 0)
        }

        // Free intervals from now to the end of the day, minus the anchors.
        let free = freeIntervals(anchors: anchors, from: now, to: windowEnd, calendar: calendar)

        var result = Result()
        guard !free.isEmpty else {
            result.spilled = softTasks.sortedForFlow(now: now)
            result.behindMinutes = behind(of: result.spilled.first, now: now, calendar: calendar)
            return result
        }

        // A single forward cursor across all tasks, so nothing double-books. Healing only ever
        // pushes work *later* — a task never starts before its planned time (we don't drag
        // future work forward just because you're free), before now, or before the previous
        // task ended.
        var cursor = now
        for task in softTasks.sortedForFlow(now: now) {
            let effort = task.effortMinutes ?? EnergyBatch.defaultEffort
            let plannedStart = DueDate.parse(task.dueDate)
            let floor = max(cursor, plannedStart ?? now, now)

            if let start = earliestFit(after: floor, minutes: effort, in: free, calendar: calendar),
               let end = calendar.date(byAdding: .minute, value: effort, to: start) {
                let drift = plannedStart.map { max(0, Int(start.timeIntervalSince($0) / 60)) } ?? 0
                result.placed.append(Placed(task: task, start: start, end: end,
                                            plannedStart: plannedStart, driftMinutes: drift))
                cursor = calendar.date(byAdding: .minute, value: bufferMinutes, to: end) ?? end
            } else {
                result.spilled.append(task)
            }
        }

        result.placed.sort { $0.start < $1.start }
        // "Behind" = how late the very next task will now start versus when it was planned.
        result.behindMinutes = result.placed.first?.driftMinutes
            ?? behind(of: result.spilled.first, now: now, calendar: calendar)
        return result
    }

    // MARK: Helpers

    /// The earliest start at or after `floor` where `minutes` fits inside one of the free
    /// intervals. Returns nil when nothing fits before the day ends.
    private static func earliestFit(after floor: Date, minutes: Int, in free: [Anchor],
                                    calendar: Calendar) -> Date? {
        for interval in free {
            let start = max(floor, interval.start)
            guard let end = calendar.date(byAdding: .minute, value: minutes, to: start),
                  end <= interval.end else { continue }
            return start
        }
        return nil
    }

    private static func endOfDay(_ now: Date, hour: Int, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: min(23, hour), minute: 0, second: 0, of: now)
    }

    /// How many minutes past its planned start a spilled task already is.
    private static func behind(of task: TaskItem?, now: Date, calendar: Calendar) -> Int {
        guard let task, let planned = DueDate.parse(task.dueDate) else { return 0 }
        return max(0, Int(now.timeIntervalSince(planned) / 60))
    }

    /// The open stretches in [from, to] once the anchors are carved out. Anchors are clipped to
    /// the window and merged, exactly like the planner's free-slot logic.
    static func freeIntervals(anchors: [Anchor], from: Date, to: Date, calendar: Calendar) -> [Anchor] {
        let busy = anchors
            .map { Anchor(start: max($0.start, from), end: min($0.end, to)) }
            .filter { $0.start < $0.end }
            .sorted { $0.start < $1.start }

        var merged: [Anchor] = []
        for interval in busy {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        var slots: [Anchor] = []
        var cursor = from
        for interval in merged {
            if interval.start > cursor { slots.append(Anchor(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if cursor < to { slots.append(Anchor(start: cursor, end: to)) }
        return slots
    }
}

private extension Array where Element == TaskItem {
    /// Flow order: whatever you're mid-way through comes first (it shouldn't jump the queue it's
    /// already in), then by planned time, then undated by title for stability.
    func sortedForFlow(now: Date) -> [TaskItem] {
        sorted { a, b in
            let aInProgress = a.status == "in_progress"
            let bInProgress = b.status == "in_progress"
            if aInProgress != bInProgress { return aInProgress }
            switch (DueDate.parse(a.dueDate), DueDate.parse(b.dueDate)) {
            case let (da?, db?) where da != db: return da < db
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
