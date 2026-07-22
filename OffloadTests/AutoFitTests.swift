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
}
