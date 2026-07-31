import Foundation

/// Clock-time formatting for display.
///
/// This used to be a static helper parked inside `CalendarView` — a 400-line view that nothing ever
/// constructed. Seven files across the app depended on that one function, which is what kept the
/// dead view alive; extracting it here is what let the view be deleted.
///
/// Two things changed in the move. It caches its formatter (the original built a fresh
/// `DateFormatter` on every call, from inside `body`, once per timed row per render — the exact
/// allocation `DueDate`'s cache exists to avoid). And it now respects the user's locale instead of
/// hardcoding `"h:mm a"`: `setLocalizedDateFormatFromTemplate` with the `j` skeleton resolves to
/// whichever hour cycle the user's region and their 24-Hour Time setting actually call for, so
/// someone on a 24-hour clock stops seeing "3:00 PM".
///
/// Deliberately not reusing `DueDate`'s formatter cache: that one pins `en_US_POSIX` because it's
/// for *parsing* stored strings, where a stable, locale-independent interpretation is the whole
/// point. Display wants the opposite.
enum TimeFormat {
    /// Keyed by locale identifier so a mid-session locale change can't serve a stale formatter.
    /// `NSCache` is internally locked, hence safe to share; it just isn't marked `Sendable`, the
    /// same reasoning `DueDate.localFormatterCache` documents.
    private nonisolated(unsafe) static let cache = NSCache<NSString, DateFormatter>()

    /// A time like "3:00 PM" — or "15:00" for a user on a 24-hour clock.
    static func time(_ date: Date) -> String {
        formatter(template: "jmm").string(from: date)
    }

    /// A time with the day attached, for contexts where the date isn't already established.
    static func dayAndTime(_ date: Date) -> String {
        formatter(template: "MMMdjmm").string(from: date)
    }

    /// A length of time like "45m" or "2h 40m". Not a clock time — a duration, which is a
    /// different question and reads differently.
    static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(max(0, minutes))m" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    private static func formatter(template: String) -> DateFormatter {
        let locale = Locale.current
        let key = "\(template)|\(locale.identifier)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let df = DateFormatter()
        df.locale = locale
        df.setLocalizedDateFormatFromTemplate(template)
        cache.setObject(df, forKey: key)
        return df
    }
}
