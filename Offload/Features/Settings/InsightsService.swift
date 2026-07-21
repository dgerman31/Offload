import Foundation
import GRDB
import FoundationModels

/// Weekly insight generation (spec §3.6): deterministic stats first, then the on-device
/// model turns them into two warm sentences. Falls back to a plain summary if the model
/// is unavailable — insight generation must never fail.
enum InsightsService {

    struct WeeklyStats: Equatable {
        var completedCount = 0
        var capturedCount = 0
        var topCategory: String?
        var busiestDay: String?
        // Insight 2.0 (punch list #5): richer signal so the note can reflect and suggest, not
        // just report. These describe open work *now*, not just this week's completions.
        var openCount = 0
        var overdueCount = 0
        var currentStreakDays = 0
        /// A few highest-priority open task titles — the concrete things still needing the user.
        var topOpenTasks: [String] = []
        /// Completed-this-week counts by category, highest first — the shape of the week's effort.
        var categoryMix: [(category: String, count: Int)] = []

        static func == (lhs: WeeklyStats, rhs: WeeklyStats) -> Bool {
            lhs.completedCount == rhs.completedCount && lhs.capturedCount == rhs.capturedCount
                && lhs.topCategory == rhs.topCategory && lhs.busiestDay == rhs.busiestDay
                && lhs.openCount == rhs.openCount && lhs.overdueCount == rhs.overdueCount
                && lhs.currentStreakDays == rhs.currentStreakDays && lhs.topOpenTasks == rhs.topOpenTasks
                && lhs.categoryMix.map { $0.category } == rhs.categoryMix.map { $0.category }
                && lhs.categoryMix.map { $0.count } == rhs.categoryMix.map { $0.count }
        }
    }

    /// Priority ordering for surfacing the most important open work first.
    private static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high": return 0
        case "low": return 2
        default: return 1
        }
    }

    /// Pure + testable rollup of the current week, plus the open-work snapshot Insight 2.0 needs.
    static func weeklyStats(
        tasks: [TaskItem],
        captures: [Capture],
        now: Date,
        calendar: Calendar = .current
    ) -> WeeklyStats {
        let iso = ISO8601DateFormatter()
        var stats = WeeklyStats()
        var categoryCounts: [String: Int] = [:]
        var dayCounts: [Int: Int] = [:]
        var completionDays = Set<Date>()
        var openTasks: [TaskItem] = []

        for task in tasks {
            if task.status == "completed" {
                guard let done = task.completedAt.flatMap({ iso.date(from: $0) }) else { continue }
                completionDays.insert(calendar.startOfDay(for: done))
                guard calendar.isDate(done, equalTo: now, toGranularity: .weekOfYear) else { continue }
                stats.completedCount += 1
                categoryCounts[task.category ?? "Other", default: 0] += 1
                dayCounts[calendar.component(.weekday, from: done), default: 0] += 1
            } else {
                stats.openCount += 1
                openTasks.append(task)
                if let due = DueDate.parse(task.dueDate), due < now { stats.overdueCount += 1 }
            }
        }

        stats.capturedCount = captures.filter {
            guard let created = iso.date(from: $0.createdAt) else { return false }
            return calendar.isDate(created, equalTo: now, toGranularity: .weekOfYear)
        }.count

        stats.topCategory = categoryCounts.max { $0.value < $1.value }?.key
        if let busiest = dayCounts.max(by: { $0.value < $1.value })?.key {
            stats.busiestDay = calendar.weekdaySymbols[busiest - 1]
        }
        stats.currentStreakDays = TaskStats.streak(days: completionDays, now: now, calendar: calendar)
        stats.categoryMix = categoryCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (category: $0.key, count: $0.value) }
        stats.topOpenTasks = openTasks
            .sorted { priorityRank($0.priority) < priorityRank($1.priority) }
            .prefix(3)
            .map(\.title)
        return stats
    }

    /// One-paragraph insight. Model-written when available, deterministic otherwise.
    @MainActor
    static func generateInsight(db: AppDatabase = .shared) async -> String {
        let data = try? await db.dbQueue.read { database in
            (try TaskItem.filter(Column("deleted") == false).fetchAll(database),
             try Capture.fetchAll(database))
        }
        guard let (tasks, captures) = data else { return "Not enough data yet — capture a few thoughts first." }
        let stats = weeklyStats(tasks: tasks, captures: captures, now: Date())

        guard stats.completedCount > 0 || stats.capturedCount > 0 else {
            return "Nothing captured this week yet. Press the Action Button and let a thought go."
        }

        let fallback = deterministicSummary(stats)

        // Insight 2.0: not a stat readout — hand the model the real week and ask for a short,
        // warm reflection plus one or two concrete next steps. Gemini first, on-device
        // otherwise, deterministic if neither can answer.
        let system = """
            You are a calm productivity companion writing a brief weekly note. Structure: two \
            short sentences of reflection on how the week went, then one or two concrete next \
            steps the person could take, drawn ONLY from their actual open or overdue tasks. \
            Warm and specific, grounded strictly in the data given — never invent tasks or \
            numbers. No emojis, no exclamation marks. Keep it under 60 words.
            """
        let prompt = """
            Completed this week: \(stats.completedCount). Captured this week: \(stats.capturedCount).
            Open tasks right now: \(stats.openCount) (overdue: \(stats.overdueCount)).
            Current daily streak: \(stats.currentStreakDays) day\(stats.currentStreakDays == 1 ? "" : "s").\
            \(stats.busiestDay.map { "\nBusiest day: \($0)." } ?? "")\
            \(stats.categoryMix.isEmpty ? "" : "\nCategory mix (completed): " + stats.categoryMix.map { "\($0.category) \($0.count)" }.joined(separator: ", ") + ".")\
            \(stats.topOpenTasks.isEmpty ? "" : "\nTop open tasks: " + stats.topOpenTasks.map { "“\($0)”" }.joined(separator: ", ") + ".")
            """
        return await AIText.generate(system: system, prompt: prompt) ?? fallback
    }

    static func deterministicSummary(_ stats: WeeklyStats) -> String {
        var parts = ["You completed \(stats.completedCount) task\(stats.completedCount == 1 ? "" : "s") this week and captured \(stats.capturedCount) thought\(stats.capturedCount == 1 ? "" : "s")."]
        if let category = stats.topCategory {
            parts.append("Most of your progress was in \(category).")
        }
        if stats.currentStreakDays >= 2 {
            parts.append("You're on a \(stats.currentStreakDays)-day streak.")
        }
        if stats.overdueCount > 0 {
            parts.append("\(stats.overdueCount) task\(stats.overdueCount == 1 ? " is" : "s are") overdue — a good place to start.")
        } else if let open = stats.topOpenTasks.first {
            parts.append("Next up: “\(open)”.")
        } else if let day = stats.busiestDay {
            parts.append("\(day) was your busiest day.")
        }
        return parts.joined(separator: " ")
    }
}
