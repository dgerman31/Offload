import Foundation

/// Lenient, multi-strategy parsing for model-emitted due dates (spec §3.2's `dueDate`
/// field). The model doesn't reliably include a timezone offset or seconds, and a bare
/// `ISO8601DateFormatter()` fails silently on anything short of the full
/// `yyyy-MM-dd'T'HH:mm:ssZ` — which was quietly dropping due dates into "Anytime" every
/// time the model omitted either. Strings without a timezone are assumed to be in the
/// device's current time zone.
enum DueDate {
    /// Local-time fallback formats, tried in order, for strings missing a timezone offset.
    /// (`[String]` is `Sendable`, so this static is fine under strict concurrency — the
    /// formatters themselves are built fresh per call below, since `ISO8601DateFormatter` /
    /// `DateFormatter` are reference types and not `Sendable`.)
    private static let localFormats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd"
    ]

    /// ISO8601 with timezone, tolerant of fractional seconds (built per call — not cached as
    /// static state, which wouldn't be concurrency-safe for a non-`Sendable` formatter).
    private static func withTimeZoneFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    private static func localFormatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = format
        df.timeZone = .current
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }

    /// Parse a due-date string using whichever strategy matches. Returns nil if none do.
    static func parse(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let d = withTimeZoneFormatter(fractionalSeconds: true).date(from: s) { return d }
        if let d = withTimeZoneFormatter(fractionalSeconds: false).date(from: s) { return d }
        for format in localFormats {
            if let d = localFormatter(format).date(from: s) { return d }
        }
        return nil
    }

    /// Re-encode to the canonical, always-parseable form (with timezone) for storage.
    static func canonicalString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Parse then re-encode so every stored due date is canonical regardless of what
    /// format the model emitted. Unparseable input is dropped (nil) rather than stored
    /// as silent garbage that would fail every future read too.
    static func normalize(_ s: String?) -> String? {
        parse(s).map(canonicalString(from:))
    }
}
