import Foundation
import EventKit
import UIKit

/// A calendar event flattened into a plain value type for the UI (spec §3.3). Deliberately
/// decoupled from `EKEvent` so the timeline logic is pure and testable, and so nothing
/// non-`Sendable` crosses an isolation boundary.
struct CalendarEvent: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    /// The owning calendar's colour as 0xRRGGBB, so events read like they do in Calendar.app.
    var colorHex: UInt32?

    /// Minutes long — used for proportional blocks and "1h 30m" labels.
    var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }
}

/// Reads the user's calendar for the UI. Behind a protocol so views/stores can be driven by a
/// fake in tests and on a denied-permission device, exactly like `CalendarWriting`.
protocol CalendarReading: Sendable {
    /// Ask for calendar access. Returns whether reading is permitted.
    func requestAccess() async -> Bool
    /// Events overlapping the half-open range, ordered by start. Never throws — a failure
    /// (no permission, no calendars) simply yields no events.
    func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

/// Real EventKit-backed reader.
struct EventKitCalendarReader: CalendarReading {
    func requestAccess() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) ?? false else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(No title)",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location?.isEmpty == false ? event.location : nil,
                    colorHex: Self.hex(from: event.calendar?.cgColor)
                )
            }
    }

    /// Flatten a calendar's CGColor to 0xRRGGBB; nil when it can't be resolved.
    private static func hex(from cgColor: CGColor?) -> UInt32? {
        guard let cgColor else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(cgColor: cgColor).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let clamp = { (v: CGFloat) in UInt32(max(0, min(255, v * 255))) }
        return (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
    }
}

/// Yields nothing — for tests and for when calendar access is unavailable.
struct EmptyCalendarReader: CalendarReading {
    func requestAccess() async -> Bool { false }
    func events(from start: Date, to end: Date) async -> [CalendarEvent] { [] }
}
