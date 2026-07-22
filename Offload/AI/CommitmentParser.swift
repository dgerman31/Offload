import Foundation

/// Feature D: turn commitment-shaped captures into `Routine`s that block out your week, instead
/// of one-off tasks that disappear once completed. This is the *deterministic* half — the AI
/// extracts the structured data, and this code maps it to the existing Routine model (which
/// `RoutinePlanner` and `RoutineService` already know how to materialise and schedule).
///
/// Decisions (locked 2026-07-21):
/// - Storage: **internal Offload blocks** — commitments live as `Routine`s, NOT written to
///   Apple Calendar. Reversible, no external side effects, visible on the Day tab.
/// - Fixed commitments (class M–Th 9–12, Tue/Thu 2–5) → fixed `Routine`s (specific days+times).
/// - Flexible commitments (gym 5×/week, afternoons) → flexible `Routine` (`timesPerWeek`=5),
///   auto-scheduled by `RoutinePlanner` into the lightest eligible days.
///
/// Pure and testable — no database, no AI calls. The caller persists the results.
enum CommitmentParser {

    /// The result of splitting a capture: routines to create, and any remaining tasks that
    /// are normal work (not recurring commitments).
    struct Result {
        var routines: [Routine] = []
        var exceptions: [RoutineException] = []
        /// Tasks that were NOT converted to routines — passed through for normal processing.
        var remainingTasks: [ExtractedTask] = []
    }

    /// Classify and convert extracted tasks into routines where appropriate. A task is treated
    /// as a commitment when it has a recurrence rule (iCalendar RRULE) — the clearest signal
    /// the AI found a repeating pattern. Tasks without recurrence pass through unchanged.
    static func parse(_ extraction: ExtractedCapture) -> Result {
        var result = Result()

        for task in extraction.tasks {
            if let routine = routineFromTask(task) {
                result.routines.append(routine)
            } else {
                result.remainingTasks.append(task)
            }
        }

        return result
    }

    // MARK: - Task → Routine conversion

    /// Try to convert a task into a routine. Returns nil if it's not a commitment.
    /// A commitment is signalled by an RRULE (FREQ=WEEKLY, FREQ=DAILY, etc.) or by
    /// multi-day scheduling patterns (the AI sets dueDate on multiple weekdays).
    private static func routineFromTask(_ task: ExtractedTask) -> Routine? {
        guard let rrule = task.recurrenceRule, !rrule.isEmpty else { return nil }

        let parsed = parseRRule(rrule)

        // Determine kind from the RRULE.
        if let weekdays = parsed.byDay, !weekdays.isEmpty {
            // Specific weekdays stated → fixed routine.
            let startMinute = minutesSinceMidnight(from: task.dueDate)
            return Routine(
                title: task.title,
                category: normalizeCategory(task.category),
                kind: .fixed,
                weekdays: weekdays,
                startMinute: startMinute,
                durationMinutes: task.effortMinutes ?? 60
            )
        } else if let count = parsed.count, count > 0 {
            // A count per interval with no specific days → flexible routine.
            // "gym 5x/week" → timesPerWeek 5.
            let (times, flex) = splitTimesAndFlex(count)
            return Routine(
                title: task.title,
                category: normalizeCategory(task.category),
                kind: .flexible,
                durationMinutes: task.effortMinutes ?? 60,
                timesPerWeek: times,
                flex: flex
            )
        } else if parsed.freq == .daily {
            // FREQ=DAILY with no BYDAY → every day of the week, fixed.
            let startMinute = minutesSinceMidnight(from: task.dueDate)
            return Routine(
                title: task.title,
                category: normalizeCategory(task.category),
                kind: .fixed,
                weekdays: Array(1...7),
                startMinute: startMinute,
                durationMinutes: task.effortMinutes ?? 60
            )
        } else if parsed.freq == .weekly {
            // FREQ=WEEKLY with no BYDAY and no COUNT → once a week, flexible.
            return Routine(
                title: task.title,
                category: normalizeCategory(task.category),
                kind: .flexible,
                durationMinutes: task.effortMinutes ?? 60,
                timesPerWeek: parsed.interval,
                flex: 0
            )
        }

        return nil
    }

    // MARK: - RRULE parser (lightweight, covers the patterns the AI emits)

    enum Frequency: String {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
    }

    struct ParsedRRule: Equatable {
        var freq: Frequency?
        var interval: Int = 1
        var byDay: [Int]?      // Calendar weekday numbers (1=Sun…7=Sat)
        var count: Int?        // e.g. "5" from COUNT=5
    }

    /// Parse a simplified iCalendar RRULE string. Handles the subset the AI emits:
    /// FREQ, INTERVAL, BYDAY, COUNT. Example: "FREQ=WEEKLY;BYDAY=MO,WE,FR;INTERVAL=1"
    static func parseRRule(_ rrule: String) -> ParsedRRule {
        var result = ParsedRRule()
        let parts = rrule
            .replacingOccurrences(of: "RRULE:", with: "")
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).uppercased()
            let val = String(kv[1])

            switch key {
            case "FREQ":
                result.freq = Frequency(rawValue: val.uppercased())
            case "INTERVAL":
                result.interval = Int(val) ?? 1
            case "BYDAY":
                result.byDay = val.split(separator: ",")
                    .compactMap { dayAbbrevToWeekday(String($0).trimmingCharacters(in: .whitespaces)) }
            case "COUNT":
                result.count = Int(val)
            default:
                break
            }
        }

        return result
    }

    /// Map iCalendar day abbreviation to Calendar weekday number (1=Sun…7=Sat).
    static func dayAbbrevToWeekday(_ abbrev: String) -> Int? {
        switch abbrev.uppercased().replacingOccurrences(of: " ", with: "") {
        case "SU": return 1
        case "MO": return 2
        case "TU": return 3
        case "WE": return 4
        case "TH": return 5
        case "FR": return 6
        case "SA": return 7
        default:   return nil
        }
    }

    // MARK: - Helpers

    /// Extract minutes-since-midnight from an ISO date string ("2026-07-20T14:00" → 840).
    static func minutesSinceMidnight(from iso: String?) -> Int? {
        guard let iso else { return nil }
        // Try ISO 8601 parse.
        let candidates = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd'T'HH:mmXXX"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in candidates {
            df.dateFormat = fmt
            if let date = df.date(from: iso) {
                let cal = Calendar.current
                let hour = cal.component(.hour, from: date)
                let minute = cal.component(.minute, from: date)
                let result = hour * 60 + minute
                // Midnight (0) usually means "no specific time stated".
                return result > 0 ? result : nil
            }
        }
        return nil
    }

    /// Split a count like 5 into (timesPerWeek: 4, flex: 1) when the number exceeds 4,
    /// giving the planner a bit of flexibility. Counts ≤4 are exact targets with no flex.
    private static func splitTimesAndFlex(_ count: Int) -> (times: Int, flex: Int) {
        if count <= 4 { return (count, 0) }
        // For ">4×/week", the base is count-1 with 1 flex, giving "4–5" style.
        return (count - 1, 1)
    }

    /// Normalise category to match CaptureMapper's expectations.
    private static func normalizeCategory(_ raw: String) -> String {
        CaptureMapper.normalizedCategory(raw)
    }
}
