import Foundation
import GRDB

/// A repeating part of your week — a class that meets Mon/Wed/Fri at 9, or a gym habit you
/// want 4–5 times but don't tie to fixed days. Routines are the skeleton the flexible day is
/// built around; individual tasks fill the gaps between them.
struct Routine: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    var category: String?
    /// "fixed" (specific weekdays + time) or "flexible" (a weekly frequency, days chosen for you).
    var kind: String
    /// For fixed routines: JSON array of `Calendar` weekday numbers (1 = Sunday … 7 = Saturday).
    var weekdays: String?
    /// For fixed routines: minutes since midnight of the start time. nil = no set time.
    var startMinute: Int?
    var durationMinutes: Int
    /// For flexible routines: the target number of sessions per week…
    var timesPerWeek: Int
    /// …with up to this many more allowed ("4–5 times" = timesPerWeek 4, flex 1).
    var flex: Int
    var active: Bool
    var createdAt: String

    static let databaseTableName = "routines"

    enum Kind: String { case fixed, flexible }
    var routineKind: Kind { Kind(rawValue: kind) ?? .fixed }

    enum CodingKeys: String, CodingKey {
        case id, title, category, kind, weekdays
        case startMinute = "start_minute"
        case durationMinutes = "duration_minutes"
        case timesPerWeek = "times_per_week"
        case flex, active
        case createdAt = "created_at"
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        category: String? = nil,
        kind: Kind = .fixed,
        weekdays: [Int] = [],
        startMinute: Int? = nil,
        durationMinutes: Int = 60,
        timesPerWeek: Int = 0,
        flex: Int = 0,
        active: Bool = true,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.kind = kind.rawValue
        self.weekdays = Routine.encodeWeekdays(weekdays)
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.timesPerWeek = timesPerWeek
        self.flex = flex
        self.active = active
        self.createdAt = createdAt
    }

    /// The weekdays this fixed routine meets, decoded.
    var weekdayNumbers: [Int] { Routine.decodeWeekdays(weekdays) }

    static func encodeWeekdays(_ days: [Int]) -> String? {
        let clean = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        guard !clean.isEmpty, let data = try? JSONEncoder().encode(clean) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeWeekdays(_ json: String?) -> [Int] {
        guard let json, let data = json.data(using: .utf8),
              let days = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return days.sorted()
    }

    /// "9:30 AM" for the start time, when set.
    var startTimeLabel: String? {
        guard let startMinute else { return nil }
        let h = startMinute / 60, m = startMinute % 60
        let suffix = h < 12 ? "AM" : "PM"
        let display = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", display, m, suffix)
    }

    /// Plain-language recurrence, for the UI ("Mon, Wed, Fri" / "4–5× a week").
    var scheduleLabel: String {
        switch routineKind {
        case .fixed:
            let names = weekdayNumbers.compactMap { Recurrence.weekdayName($0).map { String($0.prefix(3)) } }
            let days = names.isEmpty ? "Weekly" : names.joined(separator: ", ")
            return startTimeLabel.map { "\(days) · \($0)" } ?? days
        case .flexible:
            let upper = timesPerWeek + flex
            let count = flex > 0 ? "\(timesPerWeek)–\(upper)" : "\(timesPerWeek)"
            return "\(count)× a week"
        }
    }
}

/// A one-off skip: "Practice of Medicine is cancelled this Friday". Records that a routine
/// does *not* occur on a specific date, without touching the routine itself — so next week is
/// unaffected and the day it's cancelled can reflow.
struct RoutineException: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var routineId: String
    /// yyyy-MM-dd of the skipped day.
    var date: String
    var createdAt: String

    static let databaseTableName = "routine_exceptions"

    enum CodingKeys: String, CodingKey {
        case id
        case routineId = "routine_id"
        case date
        case createdAt = "created_at"
    }

    init(id: String = UUID().uuidString, routineId: String, date: String,
         createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id
        self.routineId = routineId
        self.date = date
        self.createdAt = createdAt
    }

    /// yyyy-MM-dd key for a date, the canonical form exceptions are stored and matched by.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
