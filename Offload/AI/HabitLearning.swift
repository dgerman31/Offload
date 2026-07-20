import Foundation

/// What the app has noticed about how you actually work.
///
/// Every completion is a data point nobody was reading: *when* you finish things, *how long*
/// your tasks really take versus the estimate, and which categories you reliably ignore. Feed
/// that back and the app stops being a generic organizer and starts being yours.
///
/// Everything here is derived from your own history, on-device, and used to make better
/// defaults — never to nag.
enum HabitLearning {

    struct Habits: Equatable, Sendable {
        /// Hour of day you complete most work (0–23).
        var peakHour: Int?
        /// Ratio of actual to estimated effort, when both are known. >1 means you underestimate.
        var effortBias: Double?
        /// Categories you finish reliably, and ones that pile up.
        var reliableCategories: [String] = []
        var neglectedCategories: [String] = []
        var sampleSize = 0

        /// Only worth acting on once there's enough history to mean something.
        var isConfident: Bool { sampleSize >= 12 }
    }

    /// Derive habits from completed history. Pure and testable.
    static func learn(from tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> Habits {
        var habits = Habits()
        var hourCounts: [Int: Int] = [:]
        var estimateRatios: [Double] = []
        var completedByCategory: [String: Int] = [:]
        var openByCategory: [String: Int] = [:]

        for task in tasks where !task.deleted {
            let category = task.category ?? "Other"

            guard task.status == "completed" else {
                openByCategory[category, default: 0] += 1
                continue
            }
            guard let done = DueDate.parse(task.completedAt) else { continue }

            habits.sampleSize += 1
            hourCounts[calendar.component(.hour, from: done), default: 0] += 1
            completedByCategory[category, default: 0] += 1

            // Actual duration is only knowable when we have both a start signal and an
            // estimate; creation → completion is a rough but honest proxy for short tasks.
            if let estimate = task.effortMinutes, estimate > 0,
               let created = DueDate.parse(task.createdAt),
               let actual = calendar.dateComponents([.minute], from: created, to: done).minute,
               actual > 0, actual < 60 * 24 {          // ignore anything spanning days
                estimateRatios.append(Double(actual) / Double(estimate))
            }
        }

        habits.peakHour = hourCounts.max { $0.value < $1.value }?.key

        if estimateRatios.count >= 4 {
            // Median, not mean — one task left open over a weekend shouldn't define you.
            let sorted = estimateRatios.sorted()
            habits.effortBias = sorted[sorted.count / 2]
        }

        // A category is "reliable" when most of what you take on there gets finished.
        for (category, completed) in completedByCategory {
            let open = openByCategory[category] ?? 0
            let total = completed + open
            guard total >= 3 else { continue }
            let rate = Double(completed) / Double(total)
            if rate >= 0.7 { habits.reliableCategories.append(category) }
        }
        for (category, open) in openByCategory where open >= 4 {
            let completed = completedByCategory[category] ?? 0
            let total = completed + open
            if Double(completed) / Double(total) <= 0.25 { habits.neglectedCategories.append(category) }
        }

        habits.reliableCategories.sort()
        habits.neglectedCategories.sort()
        return habits
    }

    /// A better default estimate for a new task, corrected for how you actually run.
    /// Returns nil when there isn't enough evidence to justify overriding the model.
    static func adjustedEffort(_ estimate: Int?, habits: Habits) -> Int? {
        guard let estimate, let bias = habits.effortBias, habits.isConfident else { return estimate }
        // Only correct meaningful, consistent bias — and never wildly.
        guard bias > 1.25 || bias < 0.8 else { return estimate }
        let corrected = Double(estimate) * min(2.0, max(0.6, bias))
        return max(5, Int(corrected.rounded()))
    }

    /// Plain-language notes for the Insights screen. Empty until there's real evidence.
    static func observations(_ habits: Habits) -> [String] {
        guard habits.isConfident else { return [] }
        var lines: [String] = []

        if let hour = habits.peakHour {
            lines.append("You finish most things around \(SettingsView.hourLabel(hour)).")
        }
        if let bias = habits.effortBias {
            if bias > 1.25 {
                lines.append("Your tasks tend to take about \(Int((bias - 1) * 100))% longer than estimated — worth padding blocks.")
            } else if bias < 0.8 {
                lines.append("You usually finish faster than you expect. You can probably take on a little more.")
            }
        }
        if let neglected = habits.neglectedCategories.first {
            lines.append("\(neglected) tasks pile up more than the rest. Either schedule them deliberately or let them go.")
        }
        if let reliable = habits.reliableCategories.first {
            lines.append("You're consistent with \(reliable) — that's where your follow-through is strongest.")
        }
        return lines
    }
}
