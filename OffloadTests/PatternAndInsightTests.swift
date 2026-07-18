import Testing
import Foundation
@testable import Offload

struct PatternAndInsightTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")   // pin weekdaySymbols ("Thursday", not "Thu")
        return c
    }

    private func iso(_ day: Int, month: Int = 7, hour: Int = 10) -> String {
        let d = utcCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    // MARK: Recurrence detection

    @Test("Three same-titled captures a week apart suggest WEEKLY")
    func weeklyRecurrence() {
        let tasks = [
            TaskItem(title: "Water the plants", createdAt: iso(4)),
            TaskItem(title: "water the plants!", createdAt: iso(11)),
            TaskItem(title: "Water the Plants", createdAt: iso(18))
        ]
        let suggestions = PatternDetector.recurrenceSuggestions(tasks: tasks)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].suggestedRule == "FREQ=WEEKLY")
        #expect(suggestions[0].cadenceLabel == "weekly")
        #expect(suggestions[0].taskIds.count == 3)
    }

    @Test("Daily cadence detected; below-threshold and already-recurring groups skipped")
    func cadenceAndSkips() {
        let daily = [
            TaskItem(title: "Journal", createdAt: iso(16)),
            TaskItem(title: "Journal", createdAt: iso(17)),
            TaskItem(title: "Journal", createdAt: iso(18))
        ]
        #expect(PatternDetector.recurrenceSuggestions(tasks: daily).first?.suggestedRule == "FREQ=DAILY")

        // Only two occurrences → no suggestion.
        #expect(PatternDetector.recurrenceSuggestions(tasks: Array(daily.prefix(2))).isEmpty)

        // Already recurring → skipped.
        let recurring = daily.map { t in
            var copy = t; copy.recurrenceRule = "FREQ=DAILY"; return copy
        }
        #expect(PatternDetector.recurrenceSuggestions(tasks: recurring).isEmpty)
    }

    @Test("normalize strips punctuation and case")
    func normalization() {
        #expect(PatternDetector.normalize("Water the plants!") == "water the plants")
        #expect(PatternDetector.normalize("  WATER   the... plants ") == "water the plants")
    }

    // MARK: Breakdown detection

    @Test("Long-overdue childless tasks are flagged; subtasks and fresh tasks are not")
    func breakdown() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18))!
        let overdue = TaskItem(title: "Write thesis", dueDate: iso(8))          // 10 days late
        let fresh = TaskItem(title: "New thing", dueDate: iso(17))              // 1 day late
        let child = TaskItem(title: "Sub", parentTaskId: overdue.id, dueDate: iso(1))

        let suggestions = PatternDetector.breakdownSuggestions(
            tasks: [overdue, fresh, child], now: now
        )
        // `overdue` has a child → considered broken down already; child itself is skipped.
        #expect(suggestions.isEmpty)

        let lonely = TaskItem(title: "Stuck task", dueDate: iso(8))
        let flagged = PatternDetector.breakdownSuggestions(tasks: [lonely], now: now)
        #expect(flagged.count == 1)
        #expect(flagged[0].overdueDays >= 9)
    }

    // MARK: Weekly stats

    @Test("Weekly stats roll up completions, categories, and busiest day")
    func weeklyStats() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        var a = TaskItem(title: "a", category: "Work", status: "completed"); a.completedAt = iso(16)
        var b = TaskItem(title: "b", category: "Work", status: "completed"); b.completedAt = iso(16)
        var c = TaskItem(title: "c", category: "Health", status: "completed"); c.completedAt = iso(17)
        var old = TaskItem(title: "old", category: "Work", status: "completed"); old.completedAt = iso(1)

        let captures = [Capture(rawInput: "x", createdAt: iso(16)), Capture(rawInput: "y", createdAt: iso(1))]

        let stats = InsightsService.weeklyStats(
            tasks: [a, b, c, old], captures: captures, now: now, calendar: utcCalendar
        )
        #expect(stats.completedCount == 3)      // `old` outside this week
        #expect(stats.capturedCount == 1)
        #expect(stats.topCategory == "Work")
        #expect(stats.busiestDay == "Thursday") // Jul 16, 2026 is a Thursday
        #expect(!InsightsService.deterministicSummary(stats).isEmpty)
    }
}
