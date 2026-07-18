import Foundation
import FoundationModels
import EventKit

/// Grounds the model's temporal reasoning in the user's real calendar (spec §3.3).
/// The model calls this instead of guessing: it learns the busy windows for a date and
/// schedules due times around them. All on-device; calendar data never leaves the phone.
struct CalendarAvailabilityTool: Tool {
    let name = "checkCalendarAvailability"
    let description = "Returns the user's calendar events (busy windows) for a given date, so due times can avoid conflicts."

    @Generable
    struct Arguments {
        @Guide(description: "ISO 8601 date to check, e.g. 2026-07-18")
        var date: String
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else {
            return "Calendar access not granted; assume the whole day is free."
        }

        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = calendar.timeZone
        guard let day = df.date(from: String(arguments.date.prefix(10))),
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        else {
            return "Unrecognized date; assume the day is free."
        }
        let start = calendar.startOfDay(for: day)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        guard !events.isEmpty else {
            return "No events on \(arguments.date); the whole day is free."
        }

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let busy = events
            .sorted { $0.startDate < $1.startDate }
            .map { "\(tf.string(from: $0.startDate))–\(tf.string(from: $0.endDate)) (\($0.title ?? "busy"))" }
            .joined(separator: ", ")
        return "Busy on \(arguments.date): \(busy). Schedule around these windows."
    }
}
