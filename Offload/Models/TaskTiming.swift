import Foundation

/// How a task's timing reads for someone who sets their own schedule day to day. Two words do
/// the work: a fixed clock time is "Scheduled" (a meeting, an appointment — a real commitment),
/// and a whole-day intention is "Planned for" (something you mean to get to that day, no pressure).
/// A day that has passed reads as a quiet "was planned", never a red "overdue" alarm — moving it
/// is a shrug, not a failure. Hard deadlines are handled separately; they're the one place urgency
/// is real.
enum TaskTiming {
    enum Kind: Equatable {
        case scheduled   // a fixed moment — a meeting, an appointment, a pinned time
        case planned     // a whole-day intention placed on a day
        case past        // its day/time has passed; shown softly, never as an alarm
    }

    struct Label: Equatable {
        var text: String
        var kind: Kind
    }

    /// The timing phrase for a task, or nil when it has no due date at all (it belongs in the
    /// "whenever" pile, which needs no label).
    static func describe(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) -> Label? {
        guard let due = DueDate.parse(task.dueDate) else { return nil }

        // A fixed clock time — a real commitment. Reads "Scheduled", and softens once it's past.
        if task.hasSpecificTime {
            let when = clock(due, calendar: calendar)
            return Label(text: "Scheduled · \(when)", kind: due < now ? .past : .scheduled)
        }

        // A whole-day intention. Future days are "Planned for …"; past ones a gentle "Was planned …".
        let day = dayName(due, calendar: calendar)
        if calendar.startOfDay(for: due) < calendar.startOfDay(for: now) {
            return Label(text: "Was planned \(day)", kind: .past)
        }
        return Label(text: "Planned for \(day)", kind: .planned)
    }

    /// "today 3:00 PM" / "tomorrow 3:00 PM" / "Jul 24, 3:00 PM".
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDateInToday(date) { df.dateFormat = "'today' h:mm a" }
        else if calendar.isDateInTomorrow(date) { df.dateFormat = "'tomorrow' h:mm a" }
        else if calendar.isDateInYesterday(date) { df.dateFormat = "'yesterday' h:mm a" }
        else { df.dateFormat = "MMM d, h:mm a" }
        return df.string(from: date)
    }

    /// "today" / "tomorrow" / "yesterday" / a weekday within the week / "Jul 24" otherwise.
    static func dayName(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                               to: calendar.startOfDay(for: date)).day ?? 99)
        df.dateFormat = days < 7 ? "EEE" : "MMM d"
        return df.string(from: date)
    }
}
