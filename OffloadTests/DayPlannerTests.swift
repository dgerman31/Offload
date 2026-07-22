import Testing
import Foundation
@testable import Offload

/// Free-time detection, task placement, and learning from corrections.
struct DayPlannerTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 18) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private func iso(_ hour: Int, day: Int = 18) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(hour, day: day))
    }

    private func event(_ title: String, from: Int, to: Int, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: date(from), end: date(to),
                      isAllDay: allDay, location: nil, colorHex: nil)
    }

    // MARK: Free slots

    @Test("Free slots are the working window minus meetings")
    func freeSlots() {
        let events = [event("Standup", from: 10, to: 11), event("Review", from: 14, to: 15)]
        let slots = DayPlanner.freeSlots(events: events, on: date(9), now: date(8),
                                         calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)

        #expect(slots.count == 3)
        #expect(slots[0].start == date(9) && slots[0].end == date(10))
        #expect(slots[1].start == date(11) && slots[1].end == date(14))
        #expect(slots[2].start == date(15) && slots[2].end == date(17))
    }

    @Test("Overlapping meetings merge into one busy block")
    func overlappingEvents() {
        let events = [event("A", from: 10, to: 12), event("B", from: 11, to: 13)]
        let slots = DayPlanner.freeSlots(events: events, on: date(9), now: date(8),
                                         calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        #expect(slots.count == 2)
        #expect(slots[1].start == date(13))
    }

    @Test("Planning today never schedules into the past")
    func noPastScheduling() {
        let slots = DayPlanner.freeSlots(events: [], on: date(9), now: date(13, 30),
                                         calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        #expect(slots.count == 1)
        #expect(slots[0].start == date(13, 30))
    }

    @Test("All-day events don't block time — they're context, not commitments")
    func allDayIgnored() {
        let slots = DayPlanner.freeSlots(events: [event("Holiday", from: 0, to: 23, allDay: true)],
                                         on: date(9), now: date(8),
                                         calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        #expect(slots.count == 1)
        #expect(slots[0].minutes == 8 * 60)
    }

    @Test("A fully booked day yields no free time")
    func fullyBooked() {
        let slots = DayPlanner.freeSlots(events: [event("All hands", from: 9, to: 17)],
                                         on: date(9), now: date(8),
                                         calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        #expect(slots.isEmpty)
    }

    // MARK: Candidates

    @Test("Candidates are overdue first, then priority, then quickest")
    func candidateOrdering() {
        // Whole-day so they stay flexible; a committed time would make them constraints.
        var highToday = TaskItem(title: "High today", priority: "high", dueDate: iso(15))
        highToday.dueIsAllDay = true
        var overdue = TaskItem(title: "Overdue", priority: "low", dueDate: iso(10, day: 16))
        overdue.dueIsAllDay = true

        let tasks = [
            TaskItem(title: "Low undated", priority: "low"),
            highToday,
            overdue,
            TaskItem(title: "Tomorrow", priority: "high", dueDate: iso(10, day: 19))
        ]
        let picked = DayPlanner.candidates(from: tasks, on: date(9), now: date(8), calendar: utcCalendar)
        #expect(picked.map(\.title) == ["Overdue", "High today", "Low undated"])   // tomorrow excluded
    }

    @Test("A pinned time today is a constraint, not a candidate")
    func committedTaskExcluded() {
        // A pinned time is a commitment the planner must leave alone; a soft time would reflow.
        var committed = TaskItem(title: "Standup", priority: "high", dueDate: iso(15))
        committed.pinned = true
        #expect(committed.isAnchored)
        let picked = DayPlanner.candidates(from: [committed], on: date(9), now: date(8), calendar: utcCalendar)
        #expect(picked.isEmpty)
    }

    // MARK: Planning

    @Test("Tasks fill the gaps between meetings, in order, with buffers")
    func planning() {
        let events = [event("Standup", from: 10, to: 11)]
        let tasks = [
            TaskItem(title: "Deep work", priority: "high", effortMinutes: 30),
            TaskItem(title: "Email", priority: "medium", effortMinutes: 15)
        ]
        let plan = DayPlanner.plan(tasks: tasks, events: events, on: date(9), now: date(8),
                                   calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)

        #expect(plan.scheduled.count == 2)
        #expect(plan.unplaced.isEmpty)
        let first = plan.scheduled[0]
        #expect(first.task.title == "Deep work")
        #expect(first.start == date(9))
        #expect(first.end == date(9, 30))
        // The next one starts after a buffer, not back-to-back.
        #expect(plan.scheduled[1].start == date(9, 35))
    }

    @Test("Work that can't fit is reported, not crammed in")
    func unplacedReported() {
        // Only a 30-minute window exists.
        let events = [event("Morning block", from: 9, to: 12), event("Afternoon block", from: 12, to: 17)]
        let tasks = [TaskItem(title: "Big job", priority: "high", effortMinutes: 120)]
        let plan = DayPlanner.plan(tasks: tasks, events: events, on: date(9), now: date(8),
                                   calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        #expect(plan.scheduled.isEmpty)
        #expect(plan.unplaced.map(\.title) == ["Big job"])
    }

    @Test("Tasks with no effort estimate get the default block")
    func defaultEffort() {
        let tasks = [TaskItem(title: "Unknown length")]
        let plan = DayPlanner.plan(tasks: tasks, events: [], on: date(9), now: date(8),
                                   calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        #expect(plan.scheduled.first?.minutes == EnergyBatch.defaultEffort)
    }

    @Test("Summary counts work and admits what didn't fit")
    func summary() {
        var plan = DayPlanner.Plan()
        plan.scheduled = [
            .init(task: TaskItem(title: "A"), start: date(9), end: date(10)),
            .init(task: TaskItem(title: "B"), start: date(10), end: date(10, 30))
        ]
        plan.unplaced = [TaskItem(title: "C")]
        let text = DayPlanner.summary(for: plan)
        #expect(text.contains("2 tasks"))
        #expect(text.contains("1h 30m"))
        #expect(text.contains("didn't fit"))
    }

    // MARK: Personalization

    @Test("Corrections become few-shot lessons for the extractor")
    func lessons() {
        let task = TaskItem(title: "Buy protein powder")
        let corrections = [
            Correction(taskId: task.id, field: "category", modelValue: "Personal", userValue: "Health",
                       createdAt: iso(12)),
            Correction(taskId: task.id, field: "title", modelValue: "x", userValue: "y", createdAt: iso(13))
        ]
        let learned = Personalization.lessons(corrections: corrections, tasks: [task])
        #expect(learned.count == 1)                     // title edits aren't generalisable
        #expect(learned[0].to == "Health")
        #expect(learned[0].taskTitle == "Buy protein powder")

        let fragment = Personalization.promptFragment(learned)
        #expect(fragment?.contains("belongs in Health, not Personal") == true)
    }

    @Test("No-op corrections and unknown tasks are ignored; nothing learned yields no fragment")
    func lessonsFiltering() {
        let task = TaskItem(title: "Pay rent")
        let corrections = [
            Correction(taskId: task.id, field: "category", modelValue: "Finance", userValue: "Finance",
                       createdAt: iso(12)),                                   // no actual change
            Correction(taskId: "ghost", field: "priority", modelValue: "low", userValue: "high",
                       createdAt: iso(13))                                    // task no longer exists
        ]
        #expect(Personalization.lessons(corrections: corrections, tasks: [task]).isEmpty)
        #expect(Personalization.promptFragment([]) == nil)
    }

    @Test("Only the newest correction per task+field is taught")
    func lessonsDeduped() {
        let task = TaskItem(title: "Gym session")
        let corrections = [
            Correction(taskId: task.id, field: "category", modelValue: "Personal", userValue: "Other",
                       createdAt: iso(10)),
            Correction(taskId: task.id, field: "category", modelValue: "Other", userValue: "Health",
                       createdAt: iso(16))   // newer — this is what they actually want
        ]
        let learned = Personalization.lessons(corrections: corrections, tasks: [task])
        #expect(learned.count == 1)
        #expect(learned[0].to == "Health")
    }

    // MARK: Wake-up rollover — only genuinely-overdue unplaced tasks escalate to tomorrow

    @Test("An already-overdue task that still doesn't fit today rolls to tomorrow")
    func overdueUnplacedRollsOver() {
        let overdue = TaskItem(title: "Late bill", dueDate: iso(9, day: 16))   // two days ago
        let rollover = DayPlanner.rolloverToTomorrow(from: [overdue], on: date(9), calendar: utcCalendar)
        #expect(rollover.map(\.id) == [overdue.id])
    }

    @Test("A task only due today that simply didn't fit is left alone")
    func todayUnplacedStaysPut() {
        let dueToday = TaskItem(title: "Read chapter", dueDate: iso(9, day: 18))
        #expect(DayPlanner.rolloverToTomorrow(from: [dueToday], on: date(9), calendar: utcCalendar).isEmpty)
    }

    @Test("An undated unplaced task is left alone — nothing to escalate")
    func undatedUnplacedStaysPut() {
        let undated = TaskItem(title: "Someday idea")
        #expect(DayPlanner.rolloverToTomorrow(from: [undated], on: date(9), calendar: utcCalendar).isEmpty)
    }

    @Test("Mixed unplaced list only rolls the overdue ones")
    func mixedUnplacedFiltersCorrectly() {
        let overdue = TaskItem(title: "Late bill", dueDate: iso(9, day: 16))
        let dueToday = TaskItem(title: "Read chapter", dueDate: iso(9, day: 18))
        let undated = TaskItem(title: "Someday idea")
        let result = DayPlanner.rolloverToTomorrow(from: [overdue, dueToday, undated], on: date(9), calendar: utcCalendar)
        #expect(result.map(\.id) == [overdue.id])
    }
}
