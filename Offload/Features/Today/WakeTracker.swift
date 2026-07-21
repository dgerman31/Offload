import Foundation

/// Learns when your day actually starts.
///
/// A fixed 9am assumption is wrong for anyone whose mornings move — a resident post-call, a
/// student who slept in, someone up at 5. The first time you open the app on a new day is a
/// good proxy for "awake and starting", so the planner's window and the day's framing bend to
/// that instead of a hardcoded hour.
///
/// Pure functions over `UserDefaults`, so the (small) logic is unit-testable.
enum WakeTracker {
    static let wakeDayKey = "offload.wake.day"       // yyyy-MM-dd of the last recorded wake
    static let wakeMinuteKey = "offload.wake.minute"  // minutes since midnight of that wake

    /// Wake times outside this range are treated as noise (a late-night check-in isn't a
    /// morning), and the planner never starts before it regardless.
    static let earliestHour = 5
    static let latestHour = 11

    /// Record the first open of a new day. No-op on later opens the same day, so the wake time
    /// reflects when you actually started, not the last time you glanced at the app.
    static func recordOpen(now: Date = Date(), defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        let todayKey = dayKey(now, calendar: calendar)
        guard defaults.string(forKey: wakeDayKey) != todayKey else { return }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        defaults.set(todayKey, forKey: wakeDayKey)
        defaults.set(minute, forKey: wakeMinuteKey)
    }

    /// The hour the planner should treat as the start of today — your recorded wake time,
    /// clamped to a sane window, falling back to `fallback` if today hasn't been recorded or
    /// the wake looks like a middle-of-the-night check.
    static func dayStartHour(now: Date = Date(), fallback: Int, defaults: UserDefaults = .standard,
                             calendar: Calendar = .current) -> Int {
        guard defaults.string(forKey: wakeDayKey) == dayKey(now, calendar: calendar) else { return fallback }
        let minute = defaults.integer(forKey: wakeMinuteKey)
        let hour = minute / 60
        guard hour >= earliestHour, hour <= latestHour else { return fallback }
        return hour
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
