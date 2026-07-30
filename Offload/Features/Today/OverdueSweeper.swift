import Foundation

/// The standing rule that nothing sits in a past day. Checked once per calendar day (the first
/// time Home appears that day, mirroring `WakeTracker`'s own day-boundary guard so the sweep
/// doesn't re-run — and re-write the database — on every screen visit).
///
/// An open task still sitting in a past day moves to today, silently, keeping whatever time of
/// day it had (see `TaskStore.rollToToday`).
///
/// The one exception is a task backed by a **real calendar event**. That's a commitment that
/// exists in the user's actual calendar and probably involves other people, so the app has no
/// business moving it on their behalf; it's surfaced as a "reschedule or delete?" decision.
///
/// This used to exempt anything `isAnchored` — i.e. any hand-pinned time — on the grounds that
/// the app couldn't guess what new time you'd want. That reasoning holds for an event with other
/// people in it and is much weaker for an hour you picked yourself: "the same hour, tomorrow" is
/// the obvious answer, and it's certainly better than the alternative that was actually happening,
/// which was a daily 6am ritual sitting in a decision pile forever because it was pinned to make
/// it come first.
enum OverdueSweeper {
    static let lastRunKey = "offload.overdueSweep.lastRunDay"

    /// True the first time this is checked on a new calendar day; false on every later check the
    /// same day. Marks itself run as a side effect, so call this at most once per check.
    static func shouldRun(now: Date = Date(), defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Bool {
        let todayKey = WakeTracker.dayKey(now, calendar: calendar)
        guard defaults.string(forKey: lastRunKey) != todayKey else { return false }
        defaults.set(todayKey, forKey: lastRunKey)
        return true
    }

    /// Split open, overdue tasks into what should move to today silently versus what needs a
    /// human decision because it's a real calendar commitment. Pure and testable.
    static func classify(_ tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> (autoMove: [TaskItem], needsDecision: [TaskItem]) {
        let startOfToday = calendar.startOfDay(for: now)
        let overdue = tasks.filter { task in
            guard task.status != "completed", !task.deleted, let due = DueDate.parse(task.dueDate) else { return false }
            return due < startOfToday
        }
        return (overdue.filter { $0.calendarEventId == nil },
                overdue.filter { $0.calendarEventId != nil })
    }

    /// Where a rolled-forward task lands.
    ///
    /// Extracted from the database write so the rule itself is unit-tested rather than inferred
    /// from what ended up in SQLite. Two cases:
    ///
    /// - It **had a real time**: keep that hour, and keep the pin — the hour is information the
    ///   user supplied, and flattening it to an undated intention discards it.
    /// - It was **undated or whole-day**: there's no hour to keep, so it stays a whole-day
    ///   intention and gives up any pin.
    ///
    /// A preserved hour that has already gone by today becomes the next quarter-hour instead,
    /// because landing in the past would leave the task overdue the instant it moved — rolling
    /// forward every day and never becoming actionable.
    static func rolledPlacement(
        for task: TaskItem,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (dueDate: Date, isAllDay: Bool, keepsPin: Bool) {
        guard task.hasSpecificTime, let previous = DueDate.parse(task.dueDate) else {
            return (calendar.startOfDay(for: now), true, false)
        }
        let clock = calendar.dateComponents([.hour, .minute], from: previous)
        let nextOpening = DayPlanner.roundUpToQuarterHour(now, calendar: calendar)
        let sameTimeToday = calendar.date(bySettingHour: clock.hour ?? 0,
                                          minute: clock.minute ?? 0,
                                          second: 0, of: now)
        let target = sameTimeToday.map { $0 > now ? $0 : nextOpening } ?? nextOpening
        return (target, false, true)
    }
}
