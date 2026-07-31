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

/// Live stats for the Settings and Insights tabs, derived from the app-wide task stream.
///
/// This used to open a *second* full-table `ValueObservation` of its own, which — because
/// `RootView` keeps all five tabs mounted — meant every task write anywhere in the app triggered
/// an extra full-table refetch plus an O(n) `compute` pass, to update a readout on a tab the user
/// almost certainly wasn't looking at. That's precisely the duplication `SharedTasks` exists to
/// prevent, so it reads from there instead.
///
/// `stats` being computed rather than stored is the second half of the fix: the work now happens
/// when a stats screen actually renders, not on every write. `@Observable` still tracks it
/// correctly — reading `SharedTasks.shared.allTasks` inside the getter registers that dependency
/// with whatever view called it, so the numbers stay live.
@MainActor
@Observable
final class StatsStore {
    var stats: TaskStats.Stats {
        TaskStats.compute(tasks: SharedTasks.shared.allTasks, now: Date())
    }

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    /// Joins the shared task stream. Idempotent, and already started by whichever screen got
    /// there first, so on the Settings tab this is normally a no-op.
    func observe() async {
        SharedTasks.shared.start(db: db)
    }
}
