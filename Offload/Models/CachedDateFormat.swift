import Foundation

/// Cached `DateFormatter`s for fixed display patterns.
///
/// `DateFormatter` construction is one of Foundation's more expensive routine allocations
/// (locale/calendar table setup) — the reasoning `DueDate.localFormatterCache` documents at
/// length. The *rendering* path had the same problem in three places, all of them per-row and
/// therefore per-render: `TaskRowView.formatDue`, `TaskTiming.clock`, and `TaskTiming.dayName`
/// each built a fresh formatter on every call, and the Day tab's page heading built one per page.
///
/// `TimeFormat` deliberately doesn't cover these. It formats a clock time from a *localized
/// template*, which is right for a bare time; these callers need a literal pattern (`"'Today'
/// h:mm a"`, `"EEE"`, `"EEEE, MMM d"`) because their exact output is already on screen and
/// shouldn't change. Caching the formatter is the whole point here — patterns and results are
/// untouched.
enum CachedDateFormat {
    /// Keyed by pattern *and* locale identifier, so a mid-session region change can't serve a
    /// stale formatter and a caller that pins a fixed locale (`TaskTiming` pins `en_US_POSIX`)
    /// can't collide with one that follows the device.
    ///
    /// `NSCache` is Apple's own internally-locked cache, safe to share unsynchronized; it simply
    /// isn't marked `Sendable`, the same reasoning `DueDate`'s caches document. Formatters are
    /// configured at creation and never mutated afterward.
    private nonisolated(unsafe) static let cache = NSCache<NSString, DateFormatter>()

    /// A date rendered with a literal `DateFormatter` pattern.
    static func string(from date: Date, pattern: String, locale: Locale = .current) -> String {
        formatter(pattern, locale: locale).string(from: date)
    }

    static func formatter(_ pattern: String, locale: Locale = .current) -> DateFormatter {
        let key = "\(pattern)|\(locale.identifier)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = pattern
        cache.setObject(df, forKey: key)
        return df
    }
}
