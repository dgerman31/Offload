import Foundation

/// Keeps us inside the Gemini free tier: 15 requests/minute and 500/day. When a call would
/// exceed either, the caller quietly falls back to the on-device model instead of getting a
/// 429 — so hitting the limit degrades to "still works, just less smart" rather than "broken".
///
/// An actor so the counters are safe under concurrent captures; the daily count persists across
/// launches, the per-minute window is in memory (a fresh launch resetting it is harmless).
actor AIBudget {
    static let shared = AIBudget()

    // Free-tier ceilings, kept a touch under the real limits for safety margin.
    static let maxPerMinute = 14
    static let maxPerDay = 480

    private var minuteStamps: [Date] = []

    private let dayCountKey = "offload.ai.dayCount"
    private let dayKeyKey = "offload.ai.dayKey"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reserve one request if there's budget. Returns false when we're at a ceiling — the
    /// caller should fall back rather than call the API.
    func reserve(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        // Per-minute sliding window.
        let cutoff = now.addingTimeInterval(-60)
        minuteStamps.removeAll { $0 < cutoff }
        guard minuteStamps.count < Self.maxPerMinute else { return false }

        // Per-day, reset when the date rolls over.
        let today = Self.dayKey(now, calendar: calendar)
        if defaults.string(forKey: dayKeyKey) != today {
            defaults.set(today, forKey: dayKeyKey)
            defaults.set(0, forKey: dayCountKey)
        }
        let used = defaults.integer(forKey: dayCountKey)
        guard used < Self.maxPerDay else { return false }

        minuteStamps.append(now)
        defaults.set(used + 1, forKey: dayCountKey)
        return true
    }

    /// A spent reservation that didn't actually reach the API (e.g. the request threw before
    /// sending) can be handed back so it doesn't count against the day.
    func refund(now: Date = Date()) {
        if let last = minuteStamps.indices.last { minuteStamps.remove(at: last) }
        let used = defaults.integer(forKey: dayCountKey)
        if used > 0 { defaults.set(used - 1, forKey: dayCountKey) }
    }

    /// For the Settings usage readout.
    func usedToday(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard defaults.string(forKey: dayKeyKey) == Self.dayKey(now, calendar: calendar) else { return 0 }
        return defaults.integer(forKey: dayCountKey)
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let df = DateFormatter(); df.calendar = calendar; df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
