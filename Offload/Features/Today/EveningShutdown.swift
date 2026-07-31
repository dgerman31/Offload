import Foundation

/// The end of the day, made into a decision instead of a drift.
///
/// "Plan my day" has always had no bookend. Work that didn't happen just sat there until the
/// overdue sweeper quietly moved it at some point the next morning, which means the day ended with
/// an open question — *did I get anywhere?* — and the answer arrived, unasked for, as a pile of
/// yesterday's tasks. This closes the loop: what you finished, what's left and where it's going,
/// and the one thing tomorrow starts with.
///
/// Everything here is pure and calendar-injectable, so the rules are tested rather than observed
/// at 10pm.
enum EveningShutdown {

    /// Before this, "closing the day" is premature — there's still an evening to work in. This is
    /// deliberately later than the habit nudge (5pm): a nudge is a reminder, this is a full stop.
    static let opensAfterHour = 20

    /// What the day came to.
    struct Summary: Equatable, Sendable {
        var completed: [TaskItem] = []
        /// Still open, and dated today — the things a decision is actually needed about.
        var unfinished: [TaskItem] = []
        /// Already sitting on tomorrow, so you can see what you'd be adding to.
        var tomorrow: [TaskItem] = []

        var isEmpty: Bool { completed.isEmpty && unfinished.isEmpty }
        /// What tomorrow opens with: the earliest timed thing on it.
        var firstTomorrow: TaskItem? {
            tomorrow
                .filter(\.hasSpecificTime)
                .min { (DueDate.parse($0.dueDate) ?? .distantFuture) < (DueDate.parse($1.dueDate) ?? .distantFuture) }
                ?? tomorrow.first
        }
    }

    /// Which day was last closed out, so the card leaves you alone once you've done it. A day key
    /// rather than a timestamp, for the same reason habits use one: "have I done this today" is a
    /// question about the calendar, not about elapsed hours.
    ///
    /// `nonisolated` because it's read from wherever the sheet finishes.
    nonisolated static let lastClosedKey = "eveningShutdown.lastClosedDay"

    static func isTime(now: Date = Date(), calendar: Calendar = .current, afterHour: Int = opensAfterHour) -> Bool {
        calendar.component(.hour, from: now) >= afterHour
    }

    static func recordClosed(now: Date = Date(), calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        defaults.set(WakeTracker.dayKey(now, calendar: calendar), forKey: lastClosedKey)
    }

    static func alreadyClosed(now: Date = Date(), calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: lastClosedKey) == WakeTracker.dayKey(now, calendar: calendar)
    }

    /// Whether Home should offer the card at all: late enough, not already done, and with
    /// something to say. All three matter — an empty shutdown prompt is just a chore.
    static func shouldOffer(
        tasks: [TaskItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        afterHour: Int = opensAfterHour,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard isTime(now: now, calendar: calendar, afterHour: afterHour) else { return false }
        guard !alreadyClosed(now: now, calendar: calendar, defaults: defaults) else { return false }
        return !summary(tasks: tasks, now: now, calendar: calendar).isEmpty
    }

    /// Sort the day's tasks into what happened, what didn't, and what's next.
    ///
    /// Steps are left out of all three lists: a parent's four steps would triple the length of
    /// every section and none of them is a separate decision — rolling the parent takes its steps
    /// with it. Same rule the planner and the day timeline already apply.
    static func summary(tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> Summary {
        let living = tasks.filter { !$0.deleted }
        let steps = DayPlanner.stepIds(in: living)
        // Derived from `now`, not `calendar.isDateInTomorrow`, which silently measures against the
        // system clock — the one date this function is explicitly parameterised away from.
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        var summary = Summary()

        for task in living where !steps.contains(task.id) {
            if task.status == "completed" {
                if let done = DueDate.parse(task.completedAt), calendar.isDate(done, inSameDayAs: now) {
                    summary.completed.append(task)
                }
                continue
            }
            guard let due = DueDate.parse(task.dueDate) else { continue }
            if calendar.isDate(due, inSameDayAs: now) {
                summary.unfinished.append(task)
            } else if let tomorrowStart, calendar.isDate(due, inSameDayAs: tomorrowStart) {
                summary.tomorrow.append(task)
            }
        }

        summary.completed.sort { ($0.completedAt ?? "") < ($1.completedAt ?? "") }
        summary.unfinished.sort { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
        summary.tomorrow.sort { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
        return summary
    }

    /// Where a task goes when it rolls forward a day.
    ///
    /// Same rule as the overdue sweeper's: a task that had a real hour **keeps that hour**, along
    /// with its pin, because that hour is the one thing you actually decided. Undated and whole-day
    /// work lands as whole-day tomorrow, since there's no time to keep. Unlike the sweeper there's
    /// no "that hour has already passed" case to handle — tomorrow's hours are all still ahead.
    static func tomorrowPlacement(
        for task: TaskItem,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (dueDate: Date, isAllDay: Bool, keepsPin: Bool) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        guard task.hasSpecificTime, let previous = DueDate.parse(task.dueDate) else {
            return (tomorrow, true, false)
        }
        let clock = calendar.dateComponents([.hour, .minute], from: previous)
        let sameTimeTomorrow = calendar.date(bySettingHour: clock.hour ?? 0,
                                             minute: clock.minute ?? 0,
                                             second: 0, of: tomorrow) ?? tomorrow
        return (sameTimeTomorrow, false, true)
    }

    /// The line at the top of the sheet. Credit first — the point of looking back at a day is to
    /// see that it contained something, not to be handed a list of what it didn't.
    static func headline(_ summary: Summary) -> String {
        switch (summary.completed.count, summary.unfinished.count) {
        case (0, 0):  return "A quiet day."
        case (0, _):  return "Nothing finished today."
        case (let done, 0):  return done == 1 ? "One thing done, and nothing left." : "\(done) done, and nothing left."
        case (let done, let left):
            let finished = done == 1 ? "One thing done" : "\(done) done"
            return "\(finished), \(left) still open."
        }
    }
}
