import Testing
import Foundation
@testable import Offload

struct TodayStoreTests {

    /// UTC calendar + UTC-formatted due strings so hour-of-day is deterministic.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func iso(year: Int = 2026, month: Int = 7, day: Int = 18, hour: Int) -> String {
        let date = utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    @Test("Open tasks bucket by due hour; other-day excluded; no-due -> Anytime")
    func bucketing() {
        let cal = utcCalendar
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 13))!

        let tasks = [
            TaskItem(title: "Morning standup", dueDate: iso(hour: 9)),
            TaskItem(title: "Afternoon review", dueDate: iso(hour: 14)),
            TaskItem(title: "Evening run", dueDate: iso(hour: 19)),
            TaskItem(title: "Someday idea"),                                  // no due -> Anytime
            TaskItem(title: "Tomorrow thing", dueDate: iso(day: 19, hour: 9)) // other day -> excluded
        ]

        let plan = TodayStore.plan(for: tasks, now: now, calendar: cal)
        let bySlot = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.slot, $0.tasks) })

        #expect(bySlot[.morning]?.count == 1)
        #expect(bySlot[.afternoon]?.count == 1)
        #expect(bySlot[.evening]?.count == 1)
        #expect(bySlot[.anytime]?.count == 1)
        #expect(plan.openToday == 4)   // tomorrow's task excluded
    }

    @Test("Completed-today counts toward progress but isn't listed")
    func progress() {
        let cal = utcCalendar
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 13))!

        var done = TaskItem(title: "Finished", status: "completed")
        done.completedAt = iso(hour: 10)

        let tasks = [done, TaskItem(title: "Open one")]
        let plan = TodayStore.plan(for: tasks, now: now, calendar: cal)

        #expect(plan.completedToday == 1)
        #expect(plan.openToday == 1)
        #expect(abs(plan.progress - 0.5) < 0.0001)
        // The completed task is not listed in any slot.
        #expect(plan.groups.allSatisfy { !$0.tasks.contains { $0.title == "Finished" } })
    }
}
