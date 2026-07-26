import Testing
import Foundation
@testable import Offload

/// Feature C: loose undated captures get a soft "today" slot; stated-time and structural tasks
/// (subtasks, project tasks) are left alone.
struct AutoFitTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func at(_ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: hour))!
    }

    @Test("A loose undated capture lands on today, soft and movable")
    func fitsLoose() {
        let now = at(9)
        let loose = TaskItem(title: "Read cardio chapter", effortMinutes: 30)
        let t = AutoFit.fitIntoToday(new: [loose], existing: [], now: now, calendar: cal)[0]
        #expect(t.dueDate != nil)
        #expect(t.pinned == false)   // movable — the user never asked for this time
        #expect(DueDate.parse(t.dueDate).map { cal.isDate($0, inSameDayAs: now) } == true)
    }

    @Test("A stated-time capture and a subtask are left untouched")
    func leavesFixedAndStructural() {
        let now = at(9)
        let timed = TaskItem(title: "Meet at 3", dueDate: "2026-07-20T15:00", pinned: true)
        let sub = TaskItem(title: "milk", parentTaskId: "parent-1")
        let out = AutoFit.fitIntoToday(new: [timed, sub], existing: [], now: now, calendar: cal)
        #expect(out[0].dueDate == timed.dueDate)   // stated time unchanged
        #expect(out[1].dueDate == nil)             // subtask not scheduled
    }

    @Test("A task the model stamped for today (all-day) still gets a real time slot")
    func fitsTodayAllDay() {
        let now = at(9)
        // The common case: Gemini set a due date, but no clock time (all-day today).
        let stamped = TaskItem(title: "Review notes", dueDate: "2026-07-20T00:00",
                               effortMinutes: 30, dueIsAllDay: true)
        let t = AutoFit.fitIntoToday(new: [stamped], existing: [], now: now, calendar: cal)[0]
        #expect(t.dueIsAllDay == false)            // promoted from all-day to a timed slot
        #expect(DueDate.parse(t.dueDate).map { cal.component(.hour, from: $0) >= 9 } == true)
    }

    @Test("New tasks schedule around existing timed work rather than on top of it")
    func schedulesAroundBusy() {
        let now = at(9)
        let busy = TaskItem(title: "Clinic", dueDate: "2026-07-20T09:00", effortMinutes: 120)
        let fresh = TaskItem(title: "Email advisor", effortMinutes: 30)
        let out = AutoFit.fitIntoToday(new: [fresh], existing: [busy], now: now, calendar: cal)[0]
        // 9–11 is taken, so the fresh task lands at 11:00 or later, not 9:00.
        #expect(DueDate.parse(out.dueDate).map { cal.component(.hour, from: $0) >= 11 } == true)
    }

    @Test("A task dated for another day is not dragged into today")
    func leavesOtherDays() {
        let now = at(9)
        let tomorrow = TaskItem(title: "Dentist", dueDate: "2026-07-21T00:00", dueIsAllDay: true)
        let out = AutoFit.fitIntoToday(new: [tomorrow], existing: [], now: now, calendar: cal)[0]
        #expect(out.dueDate == tomorrow.dueDate)   // untouched
    }

    // MARK: Past the day's cutoff — roll to tomorrow instead of "Anytime" today

    @Test("A capture made past the cutoff hour gets a real slot tomorrow, not dumped on today")
    func pastCutoffRollsToTomorrow() {
        let now = at(22)   // 10pm, past the default 9pm cutoff
        let loose = TaskItem(title: "Read cardio chapter", effortMinutes: 30)
        let t = AutoFit.fitIntoToday(new: [loose], existing: [], now: now, calendar: cal,
                                     cutoffHour: DayPlanner.defaultDayEndHour)[0]
        #expect(t.dueIsAllDay == false)   // a real slot, not the old "still today, all-day" fallback
        let due = DueDate.parse(t.dueDate)
        #expect(due.map { cal.isDate($0, inSameDayAs: now) } == false)   // not today
        #expect(due.map { $0 > now } == true)                            // tomorrow, in the future
    }

    @Test("Past cutoff, tomorrow's own busy time is still respected")
    func pastCutoffSchedulesAroundTomorrowsBusyWork() {
        let now = at(22)
        let busyTomorrow = TaskItem(title: "Clinic", dueDate: "2026-07-21T09:00", effortMinutes: 120)
        let fresh = TaskItem(title: "Email advisor", effortMinutes: 30)
        let out = AutoFit.fitIntoToday(new: [fresh], existing: [busyTomorrow], now: now, calendar: cal,
                                       cutoffHour: DayPlanner.defaultDayEndHour)[0]
        let due = DueDate.parse(out.dueDate)
        #expect(due.map { cal.isDate($0, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!) } == true)
        #expect(due.map { cal.component(.hour, from: $0) >= 11 } == true)   // after the 9-11 clinic block
    }

    @Test("Before the cutoff hour, today's own search still applies as before")
    func beforeCutoffStillFitsToday() {
        let now = at(20)   // 8pm, still before the default 9pm cutoff
        let loose = TaskItem(title: "Quick email", effortMinutes: 15)
        let t = AutoFit.fitIntoToday(new: [loose], existing: [], now: now, calendar: cal,
                                     cutoffHour: DayPlanner.defaultDayEndHour)[0]
        #expect(DueDate.parse(t.dueDate).map { cal.isDate($0, inSameDayAs: now) } == true)
    }

    // MARK: Nothing lands in "Anytime" — a full day rolls forward instead

    @Test("A task too long for what's left of today gets a real time tomorrow, never all-day")
    func overflowRollsToTheNextDay() {
        let now = at(19)   // 7pm, two hours before the 9pm cutoff
        // Four hours of work can't fit in two hours of remaining day, whatever the gaps look like.
        let big = TaskItem(title: "Write the discussion section", effortMinutes: 240)
        let t = AutoFit.fitIntoToday(new: [big], existing: [], now: now, calendar: cal,
                                     cutoffHour: DayPlanner.defaultDayEndHour)[0]
        #expect(t.dueIsAllDay == false)   // the whole point: a real clock time, not "Anytime"
        let due = DueDate.parse(t.dueDate)
        #expect(due != nil)
        #expect(due.map { cal.isDate($0, inSameDayAs: now) } == false)
        #expect(due.map { $0 > now } == true)
    }

    @Test("A day packed solid pushes the leftovers onto the next day, each with a real time")
    func packedDayPushesLeftoversForward() {
        let now = at(9)
        // One commitment covering the entire waking window leaves today with no usable gap.
        let allDayBusy = TaskItem(title: "Conference", dueDate: "2026-07-20T09:00", effortMinutes: 13 * 60)
        let a = TaskItem(title: "Email advisor", effortMinutes: 30)
        let b = TaskItem(title: "Order reagents", effortMinutes: 30)
        let out = AutoFit.fitIntoToday(new: [a, b], existing: [allDayBusy], now: now, calendar: cal,
                                       cutoffHour: DayPlanner.defaultDayEndHour)
        #expect(out.allSatisfy { $0.dueIsAllDay == false })
        #expect(out.allSatisfy { DueDate.parse($0.dueDate) != nil })
        // Both moved off today rather than being stacked on top of the conference.
        #expect(out.allSatisfy { task in
            DueDate.parse(task.dueDate).map { !cal.isDate($0, inSameDayAs: now) } == true
        })
    }

    @Test("A task belonging to a project is scheduled like any other, not left unplanned")
    func schedulesProjectTasks() {
        let now = at(9)
        // Captures create projects now, so skipping project tasks meant a whole new project's
        // worth of work quietly landed in "Anytime".
        let projectTask = TaskItem(title: "Draft the opening", projectId: "project-1", effortMinutes: 45)
        let t = AutoFit.fitIntoToday(new: [projectTask], existing: [], now: now, calendar: cal)[0]
        #expect(t.dueIsAllDay == false)
        #expect(DueDate.parse(t.dueDate) != nil)
    }
}
