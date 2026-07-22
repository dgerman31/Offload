import Foundation

/// The standing rule that nothing sits in a past day. Checked once per calendar day (the first
/// time Home appears that day, mirroring `WakeTracker`'s own day-boundary guard so the sweep
/// doesn't re-run — and re-write the database — on every screen visit).
///
/// A flexible task (no fixed time/date — undated, whole-day, or a soft planner-guessed time)
/// that's still open once its day has passed moves straight to today, silently: it was never a
/// commitment, so there's nothing to confirm. A task with a real, hard time and date (pinned, or
/// tied to an actual calendar event) is different — the app can't guess what new time you'd
/// actually want, so it's surfaced as a "reschedule or delete?" decision instead of moved.
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
    /// human decision because it was a real commitment. Pure and testable.
    static func classify(_ tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> (autoMove: [TaskItem], needsDecision: [TaskItem]) {
        let startOfToday = calendar.startOfDay(for: now)
        let overdue = tasks.filter { task in
            guard task.status != "completed", !task.deleted, let due = DueDate.parse(task.dueDate) else { return false }
            return due < startOfToday
        }
        return (overdue.filter { !$0.isAnchored }, overdue.filter { $0.isAnchored })
    }
}
