import Foundation

/// Everything the Home screen says about your day, computed in one pure pass so the view is
/// pure presentation. For a cognitive-offload app the headline matters as much as the counts:
/// an empty day is a *result*, not an empty state.
struct DaySummary: Sendable, Equatable {
    var greeting: String        // "Good morning"
    var headline: String        // "3 things need you today" / "Mind clear."
    var subhead: String         // supporting line under the headline

    var overdueCount = 0
    var dueTodayCount = 0
    var completedToday = 0
    var eventCount = 0
    var untimedCount = 0        // open tasks with no due date at all

    var nextEvent: CalendarEvent?
    var nextTask: TaskItem?

    /// Share of today's work already done (completed ÷ completed + remaining).
    var progress: Double {
        let total = completedToday + dueTodayCount + overdueCount
        return total == 0 ? 0 : Double(completedToday) / Double(total)
    }

    /// True when nothing is pressing — Home should feel like a reward, not a blank list.
    var isClear: Bool { overdueCount == 0 && dueTodayCount == 0 && eventCount == 0 }
}

enum DayDashboard {

    /// Time-of-day greeting. Kept separate so it's trivially testable at boundaries.
    static func greeting(for now: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: now) {
        case ..<5:   return "Still up"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:     return "Good night"
        }
    }

    /// Roll up today from live tasks + calendar events.
    static func summary(
        tasks: [TaskItem],
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> DaySummary {
        let startOfToday = calendar.startOfDay(for: now)
        var overdue: [TaskItem] = []
        var dueToday: [TaskItem] = []
        var untimed = 0
        var completedToday = 0

        for task in tasks where !task.deleted {
            if task.status == "completed" {
                if let done = DueDate.parse(task.completedAt), calendar.isDate(done, inSameDayAs: now) {
                    completedToday += 1
                }
                continue
            }
            guard let due = DueDate.parse(task.dueDate) else {
                untimed += 1
                continue
            }
            if due < startOfToday {
                overdue.append(task)
            } else if calendar.isDate(due, inSameDayAs: now) {
                dueToday.append(task)
            }
        }

        let todayEvents = events
            .filter { calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start < $1.start }

        // "Next" = the next thing that hasn't happened yet; fall back to the first of the day
        // so the card still says something useful late in the evening.
        let nextEvent = todayEvents.first { !$0.isAllDay && $0.end > now } ?? todayEvents.first

        // Overdue outranks today when suggesting what to actually do next.
        let nextTask = NextBest.pick(from: overdue.isEmpty ? dueToday : overdue)
            ?? NextBest.pick(from: tasks.filter { $0.status != "completed" && !$0.deleted })

        var summary = DaySummary(
            greeting: greeting(for: now, calendar: calendar),
            headline: "",
            subhead: "",
            overdueCount: overdue.count,
            dueTodayCount: dueToday.count,
            completedToday: completedToday,
            eventCount: todayEvents.count,
            untimedCount: untimed,
            nextEvent: nextEvent,
            nextTask: nextTask
        )
        let phrasing = headline(for: summary)
        summary.headline = phrasing.headline
        summary.subhead = phrasing.subhead
        return summary
    }

    /// The hero line. Leads with whatever is most pressing: overdue, then today's load, then
    /// a calm all-clear. Written as a sentence a person would say, never a stat dump.
    static func headline(for s: DaySummary) -> (headline: String, subhead: String) {
        if s.overdueCount > 0 {
            let noun = s.overdueCount == 1 ? "thing is" : "things are"
            let rest = s.dueTodayCount > 0 ? "\(s.dueTodayCount) more due today." : "Everything else is handled."
            return ("\(s.overdueCount) \(noun) overdue", rest)
        }
        let load = s.dueTodayCount + s.eventCount
        if load > 0 {
            let noun = load == 1 ? "thing needs" : "things need"
            var parts: [String] = []
            if s.eventCount > 0 { parts.append("\(s.eventCount) on your calendar") }
            if s.dueTodayCount > 0 { parts.append("\(s.dueTodayCount) to do") }
            return ("\(load) \(noun) you today", parts.joined(separator: " · "))
        }
        if s.completedToday > 0 {
            let noun = s.completedToday == 1 ? "task" : "tasks"
            return ("Mind clear", "\(s.completedToday) \(noun) done today. Nothing else needs you.")
        }
        if s.untimedCount > 0 {
            let noun = s.untimedCount == 1 ? "thing" : "things"
            return ("Nothing due today", "\(s.untimedCount) \(noun) waiting whenever you want them.")
        }
        return ("Mind clear", "Nothing needs you right now.")
    }
}
