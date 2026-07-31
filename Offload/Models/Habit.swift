import Foundation
import GRDB

/// A thing you mean to do every day — a gallon of water, a stretch, vitamins.
///
/// Deliberately **not** a `TaskItem`. A daily habit isn't work to be scheduled: it doesn't want a
/// time slot, it shouldn't compete for the planner's free minutes, and it must not turn into
/// overdue clutter when a day is missed. Modelling it as a task would drag all three of those in.
/// It's a checklist that resets at midnight, which is a different shape entirely.
struct Habit: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    /// SF Symbol name shown on the row.
    var symbol: String
    var sortOrder: Double
    var createdAt: String
    var deleted: Bool

    static let databaseTableName = "habits"

    enum CodingKeys: String, CodingKey {
        case id, title, symbol
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case deleted
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        symbol: String = "checkmark.circle",
        sortOrder: Double = 0,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        deleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.deleted = deleted
    }
}

/// One habit, ticked on one day. A row existing *is* the tick — there's no `done` column to get out
/// of sync, and unticking deletes the row. `day` is a local calendar day (`yyyy-MM-dd`), not a
/// timestamp, so "did I do this today" can't be broken by timezones or by what hour it happened.
struct HabitCheck: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var habitId: String
    var day: String
    var checkedAt: String

    static let databaseTableName = "habit_checks"

    enum CodingKeys: String, CodingKey {
        case id
        case habitId = "habit_id"
        case day
        case checkedAt = "checked_at"
    }

    init(
        id: String = UUID().uuidString,
        habitId: String,
        day: String,
        checkedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.habitId = habitId
        self.day = day
        self.checkedAt = checkedAt
    }
}

/// Pure helpers over a set of habits and their ticks, so the counting and the nudge rule are
/// tested rather than eyeballed on a device.
enum HabitProgress {

    /// A gentle nudge only appears once the day is genuinely getting on. Earlier than this, "2 of
    /// 6 done" is just the morning, and saying anything about it would be nagging.
    static let nudgeAfterHour = 17

    /// How much tick history the card keeps in hand. Enough for the week of dots and a streak
    /// worth the name, and small enough that it's a few hundred rows rather than a growing table.
    static let checkWindowDays = 35

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        WakeTracker.dayKey(date, calendar: calendar)
    }

    /// The last `days` days for one habit, oldest first, with today last. What the row of dots
    /// draws — a week you can read at a glance without opening anything.
    static func week(
        _ checks: [HabitCheck],
        habitId: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        days: Int = 7
    ) -> [Bool] {
        let ticked = Set(checks.filter { $0.habitId == habitId }.map(\.day))
        return (0..<days).reversed().map { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { return false }
            return ticked.contains(dayKey(date, calendar: calendar))
        }
    }

    /// Consecutive days ending today.
    ///
    /// An unticked today doesn't break the streak — it counts back from yesterday instead. A run
    /// isn't over until the day is, and a counter that resets at midnight and un-resets when you
    /// drink your water would be punishing you for the hour rather than the habit.
    static func streak(
        _ checks: [HabitCheck],
        habitId: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let ticked = Set(checks.filter { $0.habitId == habitId }.map(\.day))
        var cursor = now
        if !ticked.contains(dayKey(now, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while ticked.contains(dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Ids ticked on `day`.
    static func checkedIds(_ checks: [HabitCheck], on day: String) -> Set<String> {
        Set(checks.filter { $0.day == day }.map(\.habitId))
    }

    /// How the card reads: "4 of 6".
    static func summary(done: Int, total: Int) -> String { "\(done) of \(total)" }

    /// The subtle reminder, or `nil` when there's nothing worth saying — everything's done, there
    /// are no habits, or it's still early enough that being reminded would just be nagging.
    ///
    /// Names what's actually left rather than counting it: "Water and stretching left" is something
    /// you can act on, where "2 remaining" makes you go and look.
    static func nudge(
        habits: [Habit],
        checkedIds: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current,
        afterHour: Int = nudgeAfterHour
    ) -> String? {
        let open = habits.filter { !checkedIds.contains($0.id) }
        guard !habits.isEmpty, !open.isEmpty else { return nil }
        guard calendar.component(.hour, from: now) >= afterHour else { return nil }

        let names = open.map(\.title)
        switch names.count {
        case 1:  return "\(names[0]) still to go today."
        case 2:  return "\(names[0]) and \(names[1]) still to go today."
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more still to go today."
        }
    }

    /// The starter set, offered when the list is empty so it costs one tap rather than six.
    static func suggestedDefaults() -> [Habit] {
        [
            Habit(title: "Drink a gallon of water", symbol: "drop.fill", sortOrder: 0),
            Habit(title: "Stretch", symbol: "figure.cooldown", sortOrder: 1),
            Habit(title: "Get outside", symbol: "sun.max.fill", sortOrder: 2),
            Habit(title: "Take vitamins", symbol: "pills.fill", sortOrder: 3),
            Habit(title: "Read something", symbol: "book.fill", sortOrder: 4)
        ]
    }
}
