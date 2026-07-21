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

    private static func localFormatter(_ format: String, timeZone: TimeZone = .current) -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = format
        df.timeZone = timeZone
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

    /// Interpret a model-emitted datetime as LOCAL wall-clock, ignoring any timezone the model
    /// tacked on. Personal captures always mean the user's own time — honouring a stray "Z" is
    /// exactly how "tomorrow 2pm" became "10am two days out". Strips a trailing Z or ±HH:MM
    /// offset, then parses in the current timezone; only the model's output should use this.
    static func parseLocal(_ s: String?, timeZone: TimeZone = .current) -> Date? {
        guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let stripped = raw.replacingOccurrences(
            of: "(Z|[+-]\\d{2}:?\\d{2})$", with: "", options: .regularExpression)
        for format in localFormats {
            if let d = localFormatter(format, timeZone: timeZone).date(from: stripped) { return d }
        }
        return parse(raw)   // fall back to the tolerant parser for anything unusual
    }

    /// Local-wall-clock parse, re-encoded to the canonical stored form.
    static func normalizeLocal(_ s: String?, timeZone: TimeZone = .current) -> String? {
        parseLocal(s, timeZone: timeZone).map(canonicalString(from:))
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
