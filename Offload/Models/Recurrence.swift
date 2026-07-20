import Foundation

/// Understands the subset of iCalendar RRULE the extractor actually emits, and works out when
/// a repeating task should next come due.
///
/// Until now `recurrence_rule` was stored and then ignored — "water the plants every week"
/// was recorded as recurring and then never came back. Completing a recurring task now
/// schedules its next occurrence, which is the whole point of marking it recurring.
enum Recurrence {

    struct Rule: Equatable, Sendable {
        enum Frequency: String, Sendable {
            case daily = "DAILY"
            case weekly = "WEEKLY"
            case monthly = "MONTHLY"
            case yearly = "YEARLY"
        }

        var frequency: Frequency
        var interval: Int = 1
        /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday); empty means "same weekday".
        var weekdays: [Int] = []

        /// Human phrasing for the UI ("Every 2 weeks", "Every Monday, Friday").
        var describedPlainly: String {
            let unit: String
            switch frequency {
            case .daily:   unit = interval == 1 ? "day" : "days"
            case .weekly:  unit = interval == 1 ? "week" : "weeks"
            case .monthly: unit = interval == 1 ? "month" : "months"
            case .yearly:  unit = interval == 1 ? "year" : "years"
            }
            if frequency == .weekly, !weekdays.isEmpty {
                let names = weekdays.sorted().compactMap { Recurrence.weekdayName($0) }
                return "Every \(names.joined(separator: ", "))"
            }
            return interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)"
        }
    }

    private static let dayCodes: [String: Int] = [
        "SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7
    ]

    static func weekdayName(_ weekday: Int) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        guard weekday >= 1, weekday <= 7 else { return nil }
        return calendar.weekdaySymbols[weekday - 1]
    }

    /// Parse "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR". Tolerant of casing, whitespace, an
    /// "RRULE:" prefix, and unknown parts — anything unrecognised is simply ignored rather
    /// than failing the whole rule.
    static func parse(_ rrule: String?) -> Rule? {
        guard let raw = rrule?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let body = raw.uppercased().replacingOccurrences(of: "RRULE:", with: "")

        var frequency: Rule.Frequency?
        var interval = 1
        var weekdays: [Int] = []

        for part in body.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "FREQ":
                frequency = Rule.Frequency(rawValue: pair[1])
            case "INTERVAL":
                if let n = Int(pair[1]), n > 0 { interval = n }
            case "BYDAY":
                weekdays = pair[1].split(separator: ",").compactMap {
                    // Tolerate ordinals like "2MO" by taking the trailing day code.
                    dayCodes[String($0.suffix(2))]
                }
            default:
                continue
            }
        }

        guard let frequency else { return nil }
        return Rule(frequency: frequency, interval: interval, weekdays: weekdays.sorted())
    }

    /// The next due date strictly after `date`. Preserves the original time of day, so a task
    /// due at 9am stays a 9am task.
    static func nextOccurrence(after date: Date, rule: Rule, calendar: Calendar = .current) -> Date? {
        switch rule.frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date)

        case .weekly:
            guard !rule.weekdays.isEmpty else {
                return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)
            }
            // Walk forward to the next listed weekday; if none remain this week, jump to the
            // first listed day of the week `interval` weeks out.
            let current = calendar.component(.weekday, from: date)
            if let nextThisWeek = rule.weekdays.first(where: { $0 > current }) {
                return calendar.date(byAdding: .day, value: nextThisWeek - current, to: date)
            }
            guard let first = rule.weekdays.first,
                  let jumped = calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)
            else { return nil }
            let jumpedWeekday = calendar.component(.weekday, from: jumped)
            return calendar.date(byAdding: .day, value: first - jumpedWeekday, to: jumped)

        case .monthly:
            return calendar.date(byAdding: .month, value: rule.interval, to: date)

        case .yearly:
            return calendar.date(byAdding: .year, value: rule.interval, to: date)
        }
    }

    /// The follow-up task to insert when a recurring one is completed: same everything, fresh
    /// id, open again, due at the next occurrence. Returns nil when the task doesn't recur.
    ///
    /// `from` is the task's own due date when it has one (so a missed weekly task doesn't
    /// silently shift its schedule), otherwise the completion moment.
    static func nextInstance(of task: TaskItem, completedAt: Date, calendar: Calendar = .current) -> TaskItem? {
        guard let rule = parse(task.recurrenceRule) else { return nil }
        let base = DueDate.parse(task.dueDate) ?? completedAt

        // If the task was overdue, roll forward past now so the next one isn't already late.
        var next = nextOccurrence(after: base, rule: rule, calendar: calendar)
        var guardCount = 0
        while let candidate = next, candidate <= completedAt, guardCount < 60 {
            guardCount += 1
            next = nextOccurrence(after: candidate, rule: rule, calendar: calendar)
        }
        guard let due = next else { return nil }

        var copy = task
        copy.id = UUID().uuidString
        copy.status = "open"
        copy.completedAt = nil
        copy.createdAt = ISO8601DateFormatter().string(from: completedAt)
        copy.dueDate = DueDate.canonicalString(from: due)
        copy.calendarEventId = nil      // a fresh occurrence gets its own event, if any
        return copy
    }
}
