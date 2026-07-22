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

    @Test("A flexible overdue task auto-moves; a hard-committed one needs a decision")
    func classifiesByCommitment() {
        let flexible = TaskItem(title: "Read chapter", dueDate: iso(18), dueIsAllDay: true)   // soft, no time
        let pinned = TaskItem(title: "Meet Dr. Lee", dueDate: iso(18, 15), pinned: true)       // hard time
        let now = date(20)

        let result = OverdueSweeper.classify([flexible, pinned], now: now, calendar: utcCalendar)
        #expect(result.autoMove.map(\.id) == [flexible.id])
        #expect(result.needsDecision.map(\.id) == [pinned.id])
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
