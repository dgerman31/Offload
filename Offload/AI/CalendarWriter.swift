import Foundation
import EventKit

/// Writes real calendar events for captured appointments (spec §3.3 — the write side of the
/// calendar integration; the read side is `CalendarAvailabilityTool`). Behind a protocol so the
/// capture pipeline is testable without touching the real event store, and so the headless /
/// no-permission paths can inject a no-op. Best-effort by design: never throws — a task that
/// can't reach the calendar simply keeps no `calendarEventId`.
protocol CalendarWriting: Sendable {
    /// Create an event and return its identifier, or nil if it couldn't be created (no
    /// permission, no default calendar, save failure). All on-device; nothing leaves the phone.
    func createEvent(title: String, start: Date, durationMinutes: Int?) async -> String?

    /// Remove the event with this identifier. Returns whether it was actually deleted. Best-effort
    /// and non-throwing, like the rest of this layer — a missing event or denied access is just
    /// `false`, never a crash. Used to clean up the app's own event when its task is deleted.
    func deleteEvent(id: String) async -> Bool
}

/// A default so existing conformers (the null writer, test stubs) don't have to implement delete
/// unless they mean to — only the real EventKit writer overrides it.
extension CalendarWriting {
    func deleteEvent(id: String) async -> Bool { false }
}

/// Real EventKit-backed writer. Requests full access (already covered by the existing
/// `NSCalendarsFullAccessUsageDescription` string and the availability tool's read grant) and
/// saves to the user's default calendar.
struct EventKitCalendarWriter: CalendarWriting {
    func createEvent(title: String, start: Date, durationMinutes: Int?) async -> String? {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted, let calendar = store.defaultCalendarForNewEvents else { return nil }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        // Default to a one-hour block when we have no effort estimate.
        event.endDate = start.addingTimeInterval(TimeInterval((durationMinutes ?? 60) * 60))
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func deleteEvent(id: String) async -> Bool {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) ?? false,
              let event = store.event(withIdentifier: id) else { return false }
        do {
            try store.remove(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}

/// No-op writer for tests and any context where calendar write should be skipped.
struct NullCalendarWriter: CalendarWriting {
    func createEvent(title: String, start: Date, durationMinutes: Int?) async -> String? { nil }
}
