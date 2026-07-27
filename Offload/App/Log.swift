import Foundation
import OSLog

/// The app's logging surface.
///
/// Until this existed there was no way to find out what a build was doing on a real device: no
/// `Logger`, no `print`, no crash reporter. A failed database write, a notification that never got
/// scheduled, or an AI call that quietly fell back to the on-device model all looked identical from
/// the outside — nothing happened, and nothing said why. Every `try?` in the app was a silent
/// failure by construction.
///
/// `Logger` rather than `print` for the reason that matters here: `print` output exists only while a
/// debugger is attached, which — with no Mac in the loop — is never. Unified-log entries persist on
/// the device, survive the app being killed, come back in a sysdiagnose, and can be read back by the
/// app itself (see `recentEntries`), so they're reachable without Xcode.
///
/// **Privacy.** String interpolations in `Logger` default to `.private` and redact to `<private>`
/// when read from another process — that default is correct here and shouldn't be widened casually.
/// Captured text is the most sensitive data this app holds, so a prompt or transcript must never be
/// logged at `.public`. Log *shapes* instead: counts, durations, error kinds, HTTP statuses. Where
/// an identifier is genuinely needed to correlate two entries, `.private(mask: .hash)` gives a
/// stable token without storing the value.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Offload"

    /// Capture pipeline: transcription, extraction, and the mapping into tasks.
    static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Database writes and migrations — the home of what used to be 40+ silent `try?` sites.
    static let database = Logger(subsystem: subsystem, category: "database")
    /// AI routing: which model served a request, budget decisions, and why a call fell back.
    static let ai = Logger(subsystem: subsystem, category: "ai")
    /// Local notification scheduling and reconciliation.
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    /// EventKit reads and writes.
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    /// Scheduling: the planner, auto-fit, and routine materialization.
    static let scheduling = Logger(subsystem: subsystem, category: "scheduling")
    /// App lifecycle and background work.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Every category above, for the diagnostics screen's filter.
    static let allCategories = [
        "capture", "database", "ai", "notifications", "calendar", "scheduling", "app",
    ]
}

// MARK: Reading the log back

/// One unified-log entry, flattened into something a SwiftUI list can show and a share sheet can
/// export.
struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let category: String
    let level: String
    let message: String
}

extension Log {
    /// This app's own recent log entries, newest last.
    ///
    /// `OSLogStore(scope: .currentProcessIdentifier)` is what makes a device-side diagnostics screen
    /// possible: an app may read its *own* unified-log entries with no entitlement and no attached
    /// debugger. That's the whole point of it being here — it's the substitute for the Mac console
    /// that isn't available, and the only way a bug report from this app can carry evidence.
    ///
    /// Scoped to the current process, so it covers this launch only; anything from a previous launch
    /// is gone. `since` is clamped to the last hour by default to keep the read cheap.
    ///
    /// `nonisolated` and `throws` rather than best-effort: a diagnostics screen that silently shows
    /// an empty list when the store can't be opened would be its own invisible failure.
    nonisolated static func recentEntries(
        since interval: TimeInterval = 3600,
        categories: Set<String>? = nil
    ) throws -> [LogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(date: Date().addingTimeInterval(-interval))
        let subsystem = Self.subsystem
        return try store.getEntries(at: start)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { entry in
                guard entry.subsystem == subsystem else { return false }
                guard let categories else { return true }
                return categories.contains(entry.category)
            }
            .map { entry in
                LogEntry(date: entry.date,
                         category: entry.category,
                         level: Self.name(for: entry.level),
                         message: entry.composedMessage)
            }
    }

    private static func name(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:  return "debug"
        case .info:   return "info"
        case .notice: return "notice"
        case .error:  return "error"
        case .fault:  return "fault"
        default:      return "log"
        }
    }

    /// The recent log as one plain-text blob, ready for a share sheet.
    nonisolated static func exportText(_ entries: [LogEntry]) -> String {
        let stamp = ISO8601DateFormatter()
        return entries
            .map { "\(stamp.string(from: $0.date))  [\($0.category)] \($0.level.uppercased()): \($0.message)" }
            .joined(separator: "\n")
    }
}
