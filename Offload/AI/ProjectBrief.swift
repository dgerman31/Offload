import Foundation
import FoundationModels

/// A short written brief on where a project actually stands.
///
/// Projects accumulate tasks until nobody can remember the shape of them. This reads the whole
/// cluster — what's done, what's stalled, what's next — and says it in a few sentences, the
/// way a colleague would if you asked "where are we with this?".
///
/// Deterministic facts are computed first and handed to the model; it writes prose, it doesn't
/// invent status. If the model is unavailable the facts still read as a usable summary.
enum ProjectBrief {

    struct Facts: Equatable, Sendable {
        var title = ""
        var total = 0
        var completed = 0
        var overdue = 0
        var unscheduled = 0
        var nextUp: String?
        var stalledDays: Int?      // days since anything here was completed
        var recentlyDone: [String] = []

        var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
        var remaining: Int { max(0, total - completed) }
    }

    /// Pure rollup — no model, fully testable.
    static func facts(
        project: Project,
        tasks: [TaskItem],
        now: Date,
        calendar: Calendar = .current
    ) -> Facts {
        var facts = Facts(title: project.title)
        let startOfToday = calendar.startOfDay(for: now)
        var open: [TaskItem] = []
        var lastCompletion: Date?

        for task in tasks where !task.deleted {
            facts.total += 1
            if task.status == "completed" {
                facts.completed += 1
                if let done = DueDate.parse(task.completedAt) {
                    if lastCompletion == nil || done > lastCompletion! { lastCompletion = done }
                    facts.recentlyDone.append(task.title)
                }
                continue
            }
            open.append(task)
            if let due = DueDate.parse(task.dueDate) {
                if due < startOfToday { facts.overdue += 1 }
            } else {
                facts.unscheduled += 1
            }
        }

        facts.recentlyDone = Array(facts.recentlyDone.suffix(3))
        facts.nextUp = NextBest.pick(from: open)?.title

        // "Stalled" only means something once there's been progress to stall.
        if let lastCompletion, facts.remaining > 0 {
            facts.stalledDays = calendar.dateComponents([.day], from: lastCompletion, to: now).day
        }
        return facts
    }

    /// The fallback brief — plain, factual, always available.
    static func deterministicBrief(_ facts: Facts) -> String {
        guard facts.total > 0 else {
            return "Nothing in this project yet. Capture a few related thoughts and they'll gather here."
        }
        var parts: [String] = []
        parts.append("\(facts.completed) of \(facts.total) done.")

        if facts.overdue > 0 {
            parts.append("\(facts.overdue) task\(facts.overdue == 1 ? " is" : "s are") overdue.")
        }
        if let days = facts.stalledDays, days >= 7 {
            parts.append("Nothing has moved here in \(days) days.")
        }
        if facts.remaining == 0 {
            parts.append("Everything's finished.")
        } else if let next = facts.nextUp {
            parts.append("Next up: “\(next)”.")
        }
        if facts.unscheduled > 0 && facts.remaining > 0 {
            parts.append("\(facts.unscheduled) still \(facts.unscheduled == 1 ? "has" : "have") no date.")
        }
        return parts.joined(separator: " ")
    }

    /// The prompt payload — only facts, so the model can't invent status.
    static func prompt(_ facts: Facts) -> String {
        var lines = [
            "Project: \(facts.title)",
            "Tasks: \(facts.total) total, \(facts.completed) done, \(facts.remaining) remaining.",
            "Overdue: \(facts.overdue). Without a date: \(facts.unscheduled)."
        ]
        if let days = facts.stalledDays { lines.append("Days since anything was completed: \(days).") }
        if let next = facts.nextUp { lines.append("Most pressing remaining task: \"\(next)\".") }
        if !facts.recentlyDone.isEmpty {
            lines.append("Recently finished: " + facts.recentlyDone.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Model-written when available, deterministic otherwise. Never throws — a brief is a
    /// nicety, and failing to produce one shouldn't interrupt anything.
    @MainActor
    static func generate(project: Project, tasks: [TaskItem], now: Date = Date()) async -> String {
        let facts = facts(project: project, tasks: tasks, now: now)
        let fallback = deterministicBrief(facts)
        guard facts.total > 0 else { return fallback }

        let system = """
            You summarise where a project stands, the way a colleague would if asked "where are \
            we with this?". Two or three short sentences: what's been done, what's actually \
            blocking or next, and — only if the numbers clearly justify it — one concrete \
            suggestion. Ground every claim in the figures you're given; never invent tasks, \
            dates or reasons. Warm and plain. No emojis, no exclamation marks, under 60 words.
            """
        return await AIText.generate(system: system, prompt: prompt(facts)) ?? fallback
    }
}
