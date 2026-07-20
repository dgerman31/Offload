import Foundation

/// Pulls a date out of freeform text as you type — "lunch with Sam tomorrow 1pm" fills in the
/// date and leaves "lunch with Sam" as the title.
///
/// Uses `NSDataDetector`, the same on-device engine that turns dates blue in Messages: instant,
/// free, and offline. The Foundation Models extractor is the right tool for a whole spoken
/// thought, but it's overkill when someone is typing one line and expects the field to update
/// under their fingers.
enum QuickDate {

    struct Match: Equatable, Sendable {
        /// The text with the date phrase removed, tidied up.
        var cleanedTitle: String
        var date: Date
        /// True when the phrase named a time of day, not just a day.
        var hasTime: Bool
    }

    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    }()

    /// Find the first date reference in `text`. Returns nil when there isn't one, so callers
    /// can leave the user's own scheduling choice untouched.
    static func parse(_ text: String, relativeTo now: Date = Date()) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let detector else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector.matches(in: trimmed, options: [], range: range).first,
              let date = match.date,
              let matchedRange = Range(match.range, in: trimmed)
        else { return nil }

        // A bare number ("call 3") is far more often part of the title than a time.
        let phrase = String(trimmed[matchedRange])
        guard phrase.rangeOfCharacter(from: .letters) != nil || phrase.contains(":") else { return nil }

        var remainder = trimmed
        remainder.removeSubrange(matchedRange)
        let cleaned = tidy(remainder)
        guard !cleaned.isEmpty else { return nil }   // the whole input was a date; keep it as a title

        return Match(cleanedTitle: cleaned, date: date, hasTime: mentionsTime(phrase))
    }

    /// Did the phrase actually name a time of day? "tomorrow 1pm" did; "tomorrow" didn't, and
    /// should land on a sensible default hour rather than whatever the detector assumed.
    static func mentionsTime(_ phrase: String) -> Bool {
        let lower = phrase.lowercased()
        if lower.contains(":") { return true }
        for marker in ["am", "pm", "noon", "midnight", "o'clock", "morning", "afternoon", "evening", "tonight"]
        where lower.contains(marker) {
            return true
        }
        return false
    }

    /// Strip the connective words left dangling by removing the date phrase ("lunch with Sam
    /// on" → "lunch with Sam") and collapse whitespace.
    static func tidy(_ text: String) -> String {
        var result = text
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let danglers = ["on", "at", "by", "this", "next", "in", "for"]
        var changed = true
        while changed {
            changed = false
            for word in danglers {
                for suffix in [" \(word)", " \(word.capitalized)"] where result.hasSuffix(suffix) {
                    result = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
            // Trailing punctuation left behind by the removal.
            while let last = result.last, last == "," || last == "-" || last == ":" {
                result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return result
    }
}
