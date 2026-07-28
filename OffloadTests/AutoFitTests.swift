import Testing
import Foundation
@testable import Offload

/// Feature C: a capture always comes out of auto-fit holding a real clock time on the day it
/// belongs to — never "Anytime", and never on top of something else. Stated times and structural
/// tasks (subtasks) are left alone.
struct AutoFitTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }
    /// A due-date string carrying its own timezone, so a test never depends on the machine's.
    private func stamp(_ date: Date) -> String { DueDate.canonicalString(from: date) }

    /// The [start, start + effort) interval each result actually occupies on the clock.
    private func intervals(_ tasks: [TaskItem]) -> [(title: String, start: Date, end: Date)] {
        tasks.compactMap { (task: TaskItem) -> (title: String, start: Date, end: Date)? in
            guard !task.dueIsAllDay, let start = DueDate.parse(task.dueDate) else { return nil }
            let effort = task.effortMinutes ?? AutoFit.defaultEffortMinutes
            let end = cal.date(byAdding: .minute, value: effort, to: start)!
            return (title: task.title, start: start, end: end)
        }
    }

    /// Every pair of occupied intervals must be disjoint — half-open, so back-to-back is fine.
    private func expectNoOverlap(_ tasks: [TaskItem]) {
        let blocks = intervals(tasks)
        for i in blocks.indices {
            for j in blocks.indices where j > i {
                let (a, b) = (blocks[i], blocks[j])
                #expect(!(a.start < b.end && b.start < a.end),
                        "\(a.title) [\(a.start) – \(a.end)) overlaps \(b.title) [\(b.start) – \(b.end))")
            }
        }
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

    // MARK: Every capture gets a real time — on its OWN day

    @Test("A task dated for another day stays on that day, and is given a real time on it")
    func leavesOtherDays() {
        let now = at(9)
        let tomorrow = TaskItem(title: "Dentist", dueDate: stamp(at(0, day: 21)), dueIsAllDay: true)
        let out = AutoFit.fitIntoToday(new: [tomorrow], existing: [], now: now, calendar: cal)[0]
        let due = DueDate.parse(out.dueDate)
        #expect(due.map { cal.isDate($0, inSameDayAs: now) } == false)          // not dragged into today
        #expect(due.map { cal.isDate($0, inSameDayAs: at(0, day: 21)) } == true) // still tomorrow
        #expect(out.dueIsAllDay == false)                                        // no longer "Anytime"
    }

    /// The bug the user reported as "tasks are still being added to anytime": the old rule only
    /// ever planned *today*, so anything the model dated for a future day kept its whole-day
    /// stamp forever and surfaced under "Anytime".
    @Test("A capture dated for a future day gets a real clock time on that day, not Anytime")
    func futureDayAllDayGetsARealTime() {
        let now = at(9)
        let thursday = at(0, day: 23)
        let stamped = TaskItem(title: "Dentist follow-up", dueDate: stamp(thursday),
                               effortMinutes: 45, dueIsAllDay: true)
        let t = AutoFit.fitIntoToday(new: [stamped], existing: [], now: now, calendar: cal)[0]

        #expect(t.dueIsAllDay == false)
        let due = DueDate.parse(t.dueDate)
        #expect(due != nil)
        #expect(due.map { cal.isDate($0, inSameDayAs: thursday) } == true)   // its own day, not today
        #expect(due.map { cal.component(.hour, from: $0) == 9 } == true)     // first thing in the window
        #expect(due.map { cal.component(.minute, from: $0) % 15 == 0 } == true)
        #expect(t.pinned == false)                                           // soft: still movable
    }

    @Test("A stated clock time on a future day is left exactly where it is")
    func leavesFutureStatedTimes() {
        let now = at(9)
        let appointment = TaskItem(title: "Dentist", dueDate: stamp(at(14, day: 22)),
                                   effortMinutes: 60, pinned: true)
        let out = AutoFit.fitIntoToday(new: [appointment], existing: [], now: now, calendar: cal)[0]
        #expect(out.dueDate == appointment.dueDate)
        #expect(out.pinned == true)
    }

    // MARK: Nothing is ever double-booked

    /// The regression the user actually reported: "tasks are being scheduled overlapping times
    /// that shouldn't be possible." A capture's own stated-time task is a real commitment even
    /// though it isn't a target — leaving it out of the busy set put its untimed siblings on top
    /// of it, because it wasn't in the database yet either.
    @Test("No two tasks from one capture ever occupy the same time")
    func captureNeverDoubleBooksItself() {
        let now = at(9)
        let lecture = TaskItem(title: "Cardio lecture", dueDate: stamp(at(11)),
                               effortMinutes: 60, pinned: true)   // a real, stated 11:00–12:00
        let out = AutoFit.fitIntoToday(
            new: [lecture,
                  TaskItem(title: "Read the chapter", effortMinutes: 90),
                  TaskItem(title: "Email advisor", effortMinutes: 20),
                  TaskItem(title: "Rewrite notes", effortMinutes: 30),
                  TaskItem(title: "Flashcards", effortMinutes: 45)],
            existing: [], now: now, calendar: cal)

        expectNoOverlap(out)
        #expect(out.count == 5)
        #expect(out.allSatisfy { $0.dueIsAllDay == false })
        #expect(out.allSatisfy { DueDate.parse($0.dueDate) != nil })
        // The stated time is untouched — it's a commitment, not a suggestion.
        let stated = out.first { $0.title == "Cardio lecture" }
        #expect(stated?.dueDate == lecture.dueDate)
        #expect(stated?.pinned == true)
        // And every placed start is still on a clean quarter-hour.
        #expect(out.allSatisfy { task in
            DueDate.parse(task.dueDate).map { cal.component(.minute, from: $0) % 15 == 0 } == true
        })
    }

    @Test("Work rolling off a packed day doesn't land on the next day's own captures")
    func rolloverDoesNotCollideWithTheNextDaysWork() {
        let now = at(9)
        // Today is booked solid, so today's capture has to roll forward to tomorrow — where
        // tomorrow's own capture is also being placed in the same call.
        let conference = TaskItem(title: "Conference", dueDate: stamp(at(9)), effortMinutes: 13 * 60)
        let forToday = TaskItem(title: "Email advisor", dueDate: stamp(at(0)),
                                effortMinutes: 60, dueIsAllDay: true)
        let forTomorrow = TaskItem(title: "Order reagents", dueDate: stamp(at(0, day: 21)),
                                   effortMinutes: 60, dueIsAllDay: true)
        let out = AutoFit.fitIntoToday(new: [forToday, forTomorrow], existing: [conference],
                                       now: now, calendar: cal)

        expectNoOverlap(out)
        #expect(out.allSatisfy { $0.dueIsAllDay == false })
        // Both ended up on tomorrow, one after the other rather than stacked at 9:00.
        #expect(out.allSatisfy { task in
            DueDate.parse(task.dueDate).map { cal.isDate($0, inSameDayAs: at(0, day: 21)) } == true
        })
        let starts = out.compactMap { DueDate.parse($0.dueDate) }
        #expect(Set(starts).count == 2)
    }

    @Test("Odd-length tasks still land on quarter-hour marks, one after another")
    func placementsStayOnQuarterHours() {
        let now = at(9)
        let out = AutoFit.fitIntoToday(
            new: [TaskItem(title: "A", effortMinutes: 37),
                  TaskItem(title: "B", effortMinutes: 23),
                  TaskItem(title: "C", effortMinutes: 52),
                  TaskItem(title: "D", effortMinutes: 8)],
            existing: [], now: now, calendar: cal)

        expectNoOverlap(out)
        for task in out {
            let start = DueDate.parse(task.dueDate)
            #expect(start != nil)
            let minute = start.map { cal.component(.minute, from: $0) } ?? -1
            #expect(minute % 15 == 0, "\(task.title) started at :\(minute), not a quarter-hour")
        }
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
        expectNoOverlap(out)
    }

    /// The last resort, exercised directly: even when *every* day the search can reach is full,
    /// the task comes back with a real clock time rather than a whole-day "Anytime" intention.
    @Test("A task that fits nowhere at all still gets a real time, never Anytime")
    func neverFallsBackToAnytime() {
        let now = at(9)
        // Twenty consecutive days booked solid from the start of the window past the cutoff —
        // more than the fourteen the search will roll through.
        let wall = (0..<20).map { offset -> TaskItem in
            let start = cal.date(byAdding: .day, value: offset, to: at(9))!
            return TaskItem(title: "Conference \(offset)", dueDate: stamp(start),
                            effortMinutes: 13 * 60)
        }
        let capture = TaskItem(title: "Read the chapter", effortMinutes: 60)
        let t = AutoFit.fitIntoToday(new: [capture], existing: wall, now: now, calendar: cal,
                                     cutoffHour: DayPlanner.defaultDayEndHour)[0]

        #expect(t.dueIsAllDay == false)              // never "Anytime", however full the calendar
        let due = DueDate.parse(t.dueDate)
        #expect(due != nil)
        #expect(due.map { cal.component(.minute, from: $0) % 15 == 0 } == true)
        // And even the last-resort placement steps clear of the wall rather than sitting inside it.
        let wallEnd = cal.date(byAdding: .minute, value: 13 * 60, to: at(9))!
        #expect(due.map { $0 < at(9) || $0 >= wallEnd } == true)
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
