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
}
