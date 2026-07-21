import Testing
import Foundation
@testable import Offload

/// The self-healing timeline: soft work reflows around fixed anchors as the day slips, instead
/// of collapsing into overdue.
struct LiquidTimelineTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: hour, minute: minute))!
    }

    private func iso(_ hour: Int, _ minute: Int = 0) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(hour, minute))
    }

    /// A soft-scheduled task: has a time, not pinned.
    private func soft(_ title: String, at hour: Int, _ minute: Int = 0, effort: Int = 30) -> TaskItem {
        TaskItem(title: title, dueDate: iso(hour, minute), effortMinutes: effort, dueIsAllDay: false, pinned: false)
    }

    // MARK: The core promise

    @Test("When the day runs late, soft work slides forward instead of going overdue")
    func slidesForwardWhenLate() {
        // Both planned for the morning; it's already 11am and neither is done.
        let tasks = [soft("Write memo", at: 9, effort: 60), soft("Review PRs", at: 10, effort: 30)]
        let healed = LiquidTimeline.heal(softTasks: tasks, anchors: [], now: date(11),
                                         calendar: utcCalendar, dayEndHour: 18)

        #expect(healed.placed.count == 2)
        #expect(healed.spilled.isEmpty)
        // Nothing is scheduled in the past — the first task starts now.
        #expect(healed.placed[0].start == date(11))
        #expect(healed.placed[0].end == date(12))
        // The next flows in after a buffer, chronological.
        #expect(healed.placed[1].start == date(12, 5))
        // It knows it has slipped.
        #expect(healed.isHealing)
        #expect(healed.behindMinutes >= 60)          // memo was due 9, now flowing at 11
        #expect(healed.placed[0].hasMoved)
    }

    @Test("Soft work flows around fixed anchors, never over them")
    func flowsAroundAnchors() {
        // A 1pm meeting is immovable; a 90-minute task planned for 12:30 must split around it.
        let meeting = LiquidTimeline.Anchor(start: date(13), end: date(14))
        let tasks = [soft("Deep work", at: 12, 30, effort: 90)]
        let healed = LiquidTimeline.heal(softTasks: tasks, anchors: [meeting], now: date(12, 30),
                                         calendar: utcCalendar, dayEndHour: 18)

        #expect(healed.placed.count == 1)
        let placed = healed.placed[0]
        // Doesn't fit in the 30-minute gap before the meeting, so it lands after it.
        #expect(placed.start >= date(14))
        // And never overlaps the anchor.
        #expect(!(placed.start < date(14) && placed.end > date(13)))
    }

    @Test("A calm, on-time day reports no healing")
    func onTimeDayIsNotHealing() {
        // Planned for 2pm, and it's only 1pm — nothing has slipped.
        let tasks = [soft("Afternoon task", at: 14, effort: 30)]
        let healed = LiquidTimeline.heal(softTasks: tasks, anchors: [], now: date(13),
                                         calendar: utcCalendar, dayEndHour: 18)
        #expect(healed.placed[0].start == date(14))   // stays put
        #expect(healed.placed[0].driftMinutes == 0)
        #expect(!healed.isHealing)
    }

    @Test("Work that no longer fits before the day ends spills, honestly")
    func overfullDaySpills() {
        // Three hours of work, but only ~1.5 hours of day left.
        let tasks = [soft("A", at: 9, effort: 60), soft("B", at: 10, effort: 60), soft("C", at: 11, effort: 60)]
        let healed = LiquidTimeline.heal(softTasks: tasks, anchors: [], now: date(16, 30),
                                         calendar: utcCalendar, dayEndHour: 18)
        #expect(!healed.placed.isEmpty)
        #expect(!healed.spilled.isEmpty)             // not everything fits
        #expect(healed.isHealing)
        // Placed + spilled accounts for every task, none lost.
        #expect(healed.placed.count + healed.spilled.count == 3)
    }

    @Test("The task you're mid-way through keeps its place at the front")
    func inProgressStaysFirst() {
        var current = soft("Being done now", at: 10, effort: 30)
        current.status = "in_progress"
        let tasks = [soft("Later planned", at: 9, effort: 30), current]   // planned earlier, but not started
        let healed = LiquidTimeline.heal(softTasks: tasks, anchors: [], now: date(11),
                                         calendar: utcCalendar, dayEndHour: 18)
        #expect(healed.placed.first?.task.title == "Being done now")
    }

    @Test("A day with no free time left spills everything rather than inventing slots")
    func noFreeTime() {
        let allDay = LiquidTimeline.Anchor(start: date(9), end: date(18))
        let tasks = [soft("Anything", at: 10, effort: 30)]
        let healed = LiquidTimeline.heal(softTasks: tasks, anchors: [allDay], now: date(9),
                                         calendar: utcCalendar, dayEndHour: 18)
        #expect(healed.placed.isEmpty)
        #expect(healed.spilled.map(\.title) == ["Anything"])
    }

    // MARK: Free-interval maths

    @Test("Free intervals are the window minus merged anchors")
    func freeIntervals() {
        let anchors = [
            LiquidTimeline.Anchor(start: date(10), end: date(11)),
            LiquidTimeline.Anchor(start: date(10, 30), end: date(12)),   // overlaps the first
            LiquidTimeline.Anchor(start: date(14), end: date(15))
        ]
        let free = LiquidTimeline.freeIntervals(anchors: anchors, from: date(9), to: date(17),
                                                calendar: utcCalendar)
        #expect(free.count == 3)
        #expect(free[0].start == date(9) && free[0].end == date(10))
        #expect(free[1].start == date(12) && free[1].end == date(14))   // merged block ends at 12
        #expect(free[2].start == date(15) && free[2].end == date(17))
    }

    // MARK: Model semantics

    @Test("Anchored vs soft is decided by pinned and calendar backing")
    func anchoredVsSoft() {
        let softTask = TaskItem(title: "planner guess", dueDate: iso(14), dueIsAllDay: false, pinned: false)
        #expect(softTask.isSoftScheduled)
        #expect(!softTask.isAnchored)

        let pinnedTask = TaskItem(title: "I said 2pm", dueDate: iso(14), dueIsAllDay: false, pinned: true)
        #expect(pinnedTask.isAnchored)
        #expect(!pinnedTask.isSoftScheduled)

        var evented = TaskItem(title: "real appointment", dueDate: iso(14), dueIsAllDay: false, pinned: false)
        evented.calendarEventId = "evt-1"
        #expect(evented.isAnchored)          // a real event anchors even when unpinned

        let allDay = TaskItem(title: "someday", dueDate: iso(0), dueIsAllDay: true)
        #expect(!allDay.isAnchored && !allDay.isSoftScheduled)   // no clock time at all
    }
}
