import Testing
import Foundation
@testable import Offload

/// The standing rule that nothing sits in a past day: a flexible task moves to today silently,
/// a hard-committed one needs a human decision instead.
struct OverdueSweeperTests {
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private func date(_ day: Int, _ hour: Int = 9) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }
    private func iso(_ day: Int, _ hour: Int = 9) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour))
    }

    @Test("Only a real calendar commitment needs a decision; everything else moves itself")
    func classifiesByCommitment() {
        let flexible = TaskItem(title: "Read chapter", dueDate: iso(18), dueIsAllDay: true)
        // A hand-pinned hour used to land in the decision pile, which is how a daily 6am ritual
        // ended up stuck there forever — it was pinned precisely so it would come first.
        let pinned = TaskItem(title: "Anki: today's cards", dueDate: iso(18, 6), pinned: true)
        var meeting = TaskItem(title: "Meet Dr. Lee", dueDate: iso(18, 15), pinned: true)
        meeting.calendarEventId = "evt-real"   // exists in the user's actual calendar
        let now = date(20)

        let result = OverdueSweeper.classify([flexible, pinned, meeting], now: now, calendar: utcCalendar)
        #expect(Set(result.autoMove.map(\.id)) == Set([flexible.id, pinned.id]))
        #expect(result.needsDecision.map(\.id) == [meeting.id])
    }

    // MARK: Where it lands

    @Test("A task with a real hour keeps that hour, and keeps its pin")
    func keepsItsTime() {
        // The 6am Anki ritual, missed yesterday. Rolling it into an undated "Anytime" pile would
        // throw away the only thing that made it first — which is what used to happen.
        let ritual = TaskItem(title: "Anki: today's cards", dueDate: iso(18, 6), pinned: true)
        let placement = OverdueSweeper.rolledPlacement(for: ritual, now: date(20, 5),
                                                      calendar: utcCalendar)
        #expect(placement.dueDate == date(20, 6))
        #expect(placement.isAllDay == false)
        #expect(placement.keepsPin)
    }

    @Test("An hour that has already gone by today becomes the next quarter-hour")
    func pastHourBecomesNow() {
        // Opening the app at 9am with a missed 6am block: keeping 6am would leave it overdue the
        // instant it moved, so it would roll again tomorrow, forever.
        let ritual = TaskItem(title: "Anki: today's cards", dueDate: iso(18, 6), pinned: true)
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 20,
                                                       hour: 9, minute: 7))!
        let placement = OverdueSweeper.rolledPlacement(for: ritual, now: now, calendar: utcCalendar)
        #expect(placement.dueDate == utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 20, hour: 9, minute: 15))!)
        #expect(placement.dueDate > now)
        #expect(placement.keepsPin)
    }

    @Test("Whole-day and undated work has no hour to keep, so it stays whole-day and unpinned")
    func wholeDayStaysWholeDay() {
        let flexible = TaskItem(title: "Read chapter", dueDate: iso(18), dueIsAllDay: true)
        let placement = OverdueSweeper.rolledPlacement(for: flexible, now: date(20, 14),
                                                      calendar: utcCalendar)
        #expect(placement.dueDate == utcCalendar.startOfDay(for: date(20)))
        #expect(placement.isAllDay)
        #expect(placement.keepsPin == false)
    }

    @Test("Rolling is idempotent — a task that already landed today doesn't drift further")
    func doesNotDriftOnRepeatedRolls() {
        // The sweep runs once a day, but nothing should break if it sees the same task twice.
        let ritual = TaskItem(title: "Anki: today's cards", dueDate: iso(20, 18), pinned: true)
        let now = date(20, 9)
        let first = OverdueSweeper.rolledPlacement(for: ritual, now: now, calendar: utcCalendar)
        var moved = ritual
        moved.dueDate = DueDate.canonicalString(from: first.dueDate)
        let second = OverdueSweeper.rolledPlacement(for: moved, now: now, calendar: utcCalendar)
        #expect(second.dueDate == first.dueDate)
    }

    @Test("A task due today (not overdue) is classified as neither")
    func todayIsNeitherOverdue() {
        let dueToday = TaskItem(title: "Email boss", dueDate: iso(20))
        let result = OverdueSweeper.classify([dueToday], now: date(20), calendar: utcCalendar)
        #expect(result.autoMove.isEmpty)
        #expect(result.needsDecision.isEmpty)
    }

    @Test("A completed or deleted task is never swept, even if its date is in the past")
    func completedAndDeletedAreIgnored() {
        var completed = TaskItem(title: "Old thing", dueDate: iso(18))
        completed.status = "completed"
        var deleted = TaskItem(title: "Removed thing", dueDate: iso(18))
        deleted.deleted = true

        let result = OverdueSweeper.classify([completed, deleted], now: date(20), calendar: utcCalendar)
        #expect(result.autoMove.isEmpty)
        #expect(result.needsDecision.isEmpty)
    }

    @Test("shouldRun fires once per calendar day, not again the same day")
    func shouldRunOncePerDay() {
        let defaults = UserDefaults(suiteName: "overdue-sweep-\(UUID().uuidString)")!
        let now = date(20)
        #expect(OverdueSweeper.shouldRun(now: now, defaults: defaults, calendar: utcCalendar) == true)
        #expect(OverdueSweeper.shouldRun(now: now, defaults: defaults, calendar: utcCalendar) == false)
        // A later time the SAME day still shouldn't re-run.
        #expect(OverdueSweeper.shouldRun(now: date(20, 23), defaults: defaults, calendar: utcCalendar) == false)
        // The next day, it fires again.
        #expect(OverdueSweeper.shouldRun(now: date(21), defaults: defaults, calendar: utcCalendar) == true)
    }
}
