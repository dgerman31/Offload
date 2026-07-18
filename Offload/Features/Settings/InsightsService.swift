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
    }

    /// Pure + testable rollup of the current week.
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

        for task in tasks {
            guard task.status == "completed",
                  let done = task.completedAt.flatMap({ iso.date(from: $0) }),
                  calendar.isDate(done, equalTo: now, toGranularity: .weekOfYear)
            else { continue }
            stats.completedCount += 1
            categoryCounts[task.category ?? "Other", default: 0] += 1
            dayCounts[calendar.component(.weekday, from: done), default: 0] += 1
        }

        stats.capturedCount = captures.filter {
            guard let created = iso.date(from: $0.createdAt) else { return false }
            return calendar.isDate(created, equalTo: now, toGranularity: .weekOfYear)
        }.count

        stats.topCategory = categoryCounts.max { $0.value < $1.value }?.key
        if let busiest = dayCounts.max(by: { $0.value < $1.value })?.key {
            stats.busiestDay = calendar.weekdaySymbols[busiest - 1]
        }
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
        guard case .available = SystemLanguageModel.default.availability else { return fallback }

        let session = LanguageModelSession(instructions: """
            You write a two-sentence weekly productivity reflection. Warm, specific, \
            grounded ONLY in the numbers given. No emojis, no exclamation marks, no advice \
            unless the numbers clearly suggest it.
            """)
        let prompt = """
            This week: \(stats.completedCount) tasks completed, \(stats.capturedCount) thoughts captured.\
            \(stats.topCategory.map { " Most completed category: \($0)." } ?? "")\
            \(stats.busiestDay.map { " Busiest day: \($0)." } ?? "")
            """
        if let response = try? await session.respond(to: prompt) {
            return response.content
        }
        return fallback
    }

    static func deterministicSummary(_ stats: WeeklyStats) -> String {
        var parts = ["You completed \(stats.completedCount) task\(stats.completedCount == 1 ? "" : "s") this week and captured \(stats.capturedCount) thought\(stats.capturedCount == 1 ? "" : "s")."]
        if let category = stats.topCategory {
            parts.append("Most of your progress was in \(category).")
        }
        if let day = stats.busiestDay {
            parts.append("\(day) was your busiest day.")
        }
        return parts.joined(separator: " ")
    }
}
