import Testing
import Foundation
@testable import Offload

struct StatsAndNextBestTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func iso(_ day: Int, hour: Int = 10) -> String {
        let d = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    // MARK: Stats

    @Test("Counts completed today / week / open")
    func counts() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        var doneToday = TaskItem(title: "a", status: "completed"); doneToday.completedAt = iso(18)
        var doneEarlierWeek = TaskItem(title: "b", status: "completed"); doneEarlierWeek.completedAt = iso(16)
        let open1 = TaskItem(title: "c")
        let open2 = TaskItem(title: "d")

        let s = TaskStats.compute(tasks: [doneToday, doneEarlierWeek, open1, open2], now: now, calendar: utcCalendar)
        #expect(s.completedToday == 1)
        #expect(s.completedThisWeek == 2)
        #expect(s.openCount == 2)
    }

    @Test("Streak counts consecutive days ending today; breaks on a gap")
    func streak() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        func day(_ d: Int) -> Date { utcCalendar.startOfDay(for: utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: d))!) }

        // 18 (today), 17, 16 consecutive; gap at 15 missing, 14 present but not counted.
        let days: Set<Date> = [day(18), day(17), day(16), day(14)]
        #expect(TaskStats.streak(days: days, now: now, calendar: utcCalendar) == 3)

        // No completion today or yesterday => streak 0.
        #expect(TaskStats.streak(days: [day(10)], now: now, calendar: utcCalendar) == 0)

        // Grace: yesterday only still counts as a current streak of 1.
        #expect(TaskStats.streak(days: [day(17)], now: now, calendar: utcCalendar) == 1)
    }

    // MARK: NextBest

    @Test("Picks highest priority, then least effort, then soonest due")
    func nextBest() {
        let tasks = [
            TaskItem(title: "Low pri", priority: "low", effortMinutes: 5),
            TaskItem(title: "High long", priority: "high", effortMinutes: 60),
            TaskItem(title: "High short", priority: "high", effortMinutes: 10),
            TaskItem(title: "Done high", priority: "high", status: "completed")
        ]
        #expect(NextBest.pick(from: tasks)?.title == "High short")   // high + least effort; completed ignored
        #expect(NextBest.pick(from: []) == nil)
        #expect(NextBest.pick(from: [TaskItem(title: "only", status: "completed")]) == nil)
    }
}
