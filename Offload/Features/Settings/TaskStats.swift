import Foundation
import GRDB

/// Completion stats + streak (pure, testable). Deliberately deterministic — no model.
enum TaskStats {
    struct Stats: Equatable, Sendable {
        var completedToday = 0
        var completedThisWeek = 0
        var currentStreakDays = 0
        var openCount = 0
    }

    static func compute(tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> Stats {
        let iso = ISO8601DateFormatter()
        var stats = Stats()
        var completionDays = Set<Date>()

        for task in tasks {
            if task.status == "completed" {
                if let done = task.completedAt.flatMap({ iso.date(from: $0) }) {
                    completionDays.insert(calendar.startOfDay(for: done))
                    if calendar.isDate(done, inSameDayAs: now) { stats.completedToday += 1 }
                    if calendar.isDate(done, equalTo: now, toGranularity: .weekOfYear) { stats.completedThisWeek += 1 }
                }
            } else {
                stats.openCount += 1
            }
        }
        stats.currentStreakDays = streak(days: completionDays, now: now, calendar: calendar)
        return stats
    }

    /// Consecutive days with ≥1 completion, ending today (or yesterday, as a grace day).
    static func streak(days: Set<Date>, now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }
}

/// Observes tasks and publishes live stats for the Settings tab.
@MainActor
@Observable
final class StatsStore {
    private(set) var stats = TaskStats.Stats()

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try TaskItem.filter(Column("deleted") == false).fetchAll(db)
        }
        do {
            for try await tasks in observation.values(in: db.dbQueue) {
                stats = TaskStats.compute(tasks: tasks, now: Date())
            }
        } catch {
            // Observation ended.
        }
    }
}
