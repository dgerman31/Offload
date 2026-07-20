import Foundation

/// A read on the week, not just the day.
///
/// Daily planning handles "what now?" but misses the slower failures: the task you've snoozed
/// four times, the project nothing has touched in a fortnight, the day you reliably overload.
/// Those only show up when you step back — so this computes them deterministically and says
/// them plainly.
enum WeekReview {

    struct Findings: Equatable, Sendable {
        var completed = 0
        var captured = 0
        var busiestWeekday: String?
        var quietestWeekday: String?
        /// Open tasks whose due date has been pushed well past their creation — the ones you
        /// keep deferring rather than deciding about.
        var chronicallyDeferred: [String] = []
        /// Open, undated, and old — quietly rotting.
        var stale: [String] = []
        var overdue = 0
        var completionRate: Double = 0     // completed ÷ (completed + still-open-from-this-week)

        var isEmpty: Bool { completed == 0 && captured == 0 && overdue == 0 && stale.isEmpty }
    }

    /// How long an undated task can sit before it counts as stale.
    static let staleDays = 21
    /// How far past creation a due date must sit to look like repeated deferral.
    static let deferredDays = 10

    static func findings(
        tasks: [TaskItem],
        now: Date,
        calendar: Calendar = .current
    ) -> Findings {
        var f = Findings()
        var completionsByWeekday: [Int: Int] = [:]
        var openFromThisWeek = 0
        let startOfToday = calendar.startOfDay(for: now)

        for task in tasks where !task.deleted {
            let created = DueDate.parse(task.createdAt)

            if task.status == "completed" {
                guard let done = DueDate.parse(task.completedAt) else { continue }
                if calendar.isDate(done, equalTo: now, toGranularity: .weekOfYear) {
                    f.completed += 1
                    completionsByWeekday[calendar.component(.weekday, from: done), default: 0] += 1
                }
                continue
            }

            // Open work.
            if let created, calendar.isDate(created, equalTo: now, toGranularity: .weekOfYear) {
                openFromThisWeek += 1
                f.captured += 1
            }

            if let due = DueDate.parse(task.dueDate) {
                if due < startOfToday { f.overdue += 1 }
                // Pushed far beyond when it was first captured.
                if let created,
                   let gap = calendar.dateComponents([.day], from: created, to: due).day,
                   gap >= deferredDays {
                    f.chronicallyDeferred.append(task.title)
                }
            } else if let created,
                      let age = calendar.dateComponents([.day], from: created, to: now).day,
                      age >= staleDays {
                f.stale.append(task.title)
            }
        }

        f.chronicallyDeferred = Array(f.chronicallyDeferred.prefix(3))
        f.stale = Array(f.stale.prefix(3))

        if let busiest = completionsByWeekday.max(by: { $0.value < $1.value })?.key {
            f.busiestWeekday = weekdayName(busiest, calendar: calendar)
        }
        if completionsByWeekday.count > 1,
           let quietest = completionsByWeekday.min(by: { $0.value < $1.value })?.key {
            f.quietestWeekday = weekdayName(quietest, calendar: calendar)
        }

        let denominator = f.completed + openFromThisWeek
        f.completionRate = denominator == 0 ? 0 : Double(f.completed) / Double(denominator)
        return f
    }

    static func weekdayName(_ weekday: Int, calendar: Calendar) -> String? {
        let symbols = calendar.weekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return nil }
        return symbols[weekday - 1]
    }

    /// Plain-language observations, most useful first. Each one is something you could act on.
    static func observations(_ f: Findings) -> [String] {
        var lines: [String] = []

        if f.completed > 0 {
            lines.append("You closed \(f.completed) task\(f.completed == 1 ? "" : "s") this week.")
        }
        if f.overdue > 0 {
            lines.append("\(f.overdue) \(f.overdue == 1 ? "is" : "are") past due — worth deciding about rather than carrying.")
        }
        if let busiest = f.busiestWeekday {
            lines.append("\(busiest) was your strongest day.")
        }
        if !f.chronicallyDeferred.isEmpty {
            let names = f.chronicallyDeferred.map { "“\($0)”" }.joined(separator: ", ")
            lines.append("You keep pushing \(names). If it isn't happening, dropping it is a decision too.")
        }
        if !f.stale.isEmpty {
            let names = f.stale.map { "“\($0)”" }.joined(separator: ", ")
            lines.append("\(names) \(f.stale.count == 1 ? "has" : "have") sat undated for weeks.")
        }
        if f.completed > 0 && f.completionRate >= 0.7 {
            lines.append("You finished most of what you took on — that's a well-sized week.")
        } else if f.completionRate > 0 && f.completionRate < 0.3 && f.captured >= 5 {
            lines.append("You captured a lot more than you closed. Consider taking on less, not working faster.")
        }
        if lines.isEmpty {
            lines.append("A quiet week. Nothing needs untangling.")
        }
        return lines
    }
}
