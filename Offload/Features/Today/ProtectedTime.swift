import Foundation

/// A recurring stretch of the week the planner may never fill: study, gym, clinic, meals,
/// whatever you've already decided that time is for.
///
/// The scheduler's model of your week used to have exactly two facts in it — when your day starts
/// and when it ends — and it treated every minute between them as fair game. So the hour you keep
/// for the gym, or the evening block you actually study in, was open time as far as auto-fit was
/// concerned, and it filled them. Declaring those hours is what turns "how many hours do I have"
/// from a number the app guesses into one it knows.
///
/// **Sleep is deliberately not modelled here.** The waking window
/// (`DayPlanner.storedDayStartHour`/`storedDayEndHour`) already bounds everything the planner
/// does, so a sleep block would be a second, redundant way to say the same thing — and two
/// settings that must agree eventually disagree. "My week" shows the waking window at the top for
/// exactly that reason: one screen, one place, but still one setting.
struct ProtectedBlock: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    /// Which weekdays this applies to, as `Calendar`'s 1-based weekday numbers (1 = Sunday).
    /// A set rather than a bitmask: it round-trips through `Codable` legibly and there's no
    /// decoding to get wrong at 5am when someone's schedule is off by a day.
    var weekdays: Set<Int>
    /// Minutes from midnight. Both are within a single day — see the note on sleep above.
    var startMinute: Int
    var endMinute: Int
    /// Drives the icon and colour only; the planner treats every kind identically.
    var kind: Kind
    /// Off keeps the block without applying it — a rotation that pauses for two weeks shouldn't
    /// have to be deleted and retyped.
    var isEnabled: Bool

    enum Kind: String, Codable, CaseIterable, Sendable {
        case study, gym, meal, work, custom

        var symbol: String {
            switch self {
            case .study:  return "book.fill"
            case .gym:    return "figure.strengthtraining.traditional"
            case .meal:   return "fork.knife"
            case .work:   return "stethoscope"
            case .custom: return "lock.fill"
            }
        }

        var label: String {
            switch self {
            case .study:  return "Study"
            case .gym:    return "Gym"
            case .meal:   return "Meal"
            case .work:   return "Clinical"
            case .custom: return "Blocked"
            }
        }
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        weekdays: Set<Int>,
        startMinute: Int,
        endMinute: Int,
        kind: Kind = .custom,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.kind = kind
        self.isEnabled = isEnabled
    }

    /// Minutes this block covers — zero when it's been given a backwards or empty range.
    var minutes: Int { max(0, endMinute - startMinute) }
}

/// Storage and expansion for `ProtectedBlock`s.
///
/// Kept in `UserDefaults` rather than SQLite, which is a deliberate call: these are a handful of
/// settings-shaped rows describing how the *app* should behave, not captured content, and the app
/// already reads its waking window the same way (`DayPlanner.storedDayEndHour`). That buys a
/// synchronous, `nonisolated` read, which is what lets the pure planner take them as a plain
/// parameter instead of every scheduling path growing a database round-trip.
enum ProtectedTime {
    static let storageKey = "offload.protectedBlocks"

    /// Prefixed so a generated block can never be mistaken for a real EventKit event or a
    /// task-derived one — the Day tab checks this to know what it must not let you tap or drag.
    static let eventIdPrefix = "protected-"

    /// A deliberately unremarkable slate: protected time is a constraint you read past, not a
    /// commitment competing for attention with your actual work.
    static let colorHex: UInt32 = 0x788291

    static func isProtected(eventId: String) -> Bool { eventId.hasPrefix(eventIdPrefix) }

    nonisolated static func stored(defaults: UserDefaults = .standard) -> [ProtectedBlock] {
        guard let data = defaults.data(forKey: storageKey),
              let blocks = try? JSONDecoder().decode([ProtectedBlock].self, from: data)
        else { return [] }
        return blocks
    }

    nonisolated static func save(_ blocks: [ProtectedBlock], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(blocks) else {
            // A settings write that silently does nothing is how a preference "won't stick".
            Log.scheduling.error("Could not encode \(blocks.count, privacy: .public) protected block(s)")
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    /// The blocks that apply on `day`, as busy intervals the planner already knows how to avoid.
    ///
    /// Expressed as `CalendarEvent`s on purpose: free time is computed by subtracting events from
    /// the waking window, so protected time needs no new concept anywhere downstream — it's just
    /// more of what's already there. Ids are prefixed so a protected block can never collide with
    /// a real EventKit event or a task-derived block.
    static func busyBlocks(
        on day: Date,
        blocks: [ProtectedBlock],
        calendar: Calendar = .current
    ) -> [CalendarEvent] {
        let weekday = calendar.component(.weekday, from: day)
        let startOfDay = calendar.startOfDay(for: day)
        return blocks.compactMap { block in
            guard block.isEnabled, block.minutes > 0, block.weekdays.contains(weekday),
                  let start = calendar.date(byAdding: .minute, value: block.startMinute, to: startOfDay),
                  let end = calendar.date(byAdding: .minute, value: block.endMinute, to: startOfDay)
            else { return nil }
            return CalendarEvent(id: eventIdPrefix + block.id, title: block.title, start: start,
                                 end: end, isAllDay: false, location: nil, colorHex: colorHex)
        }
    }

    /// A starter set offered on the "My week" screen when it's empty — the blocks a student
    /// almost certainly has, pre-filled so the feature costs one tap instead of six forms.
    static func suggestedDefaults() -> [ProtectedBlock] {
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]       // Monday–Friday
        let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
        return [
            ProtectedBlock(title: "Study", weekdays: weekdays,
                           startMinute: 19 * 60, endMinute: 21 * 60, kind: .study),
            ProtectedBlock(title: "Gym", weekdays: [2, 4, 6],
                           startMinute: 17 * 60, endMinute: 18 * 60 + 30, kind: .gym),
            ProtectedBlock(title: "Lunch", weekdays: everyDay,
                           startMinute: 12 * 60, endMinute: 12 * 60 + 45, kind: .meal),
            ProtectedBlock(title: "Dinner", weekdays: everyDay,
                           startMinute: 18 * 60 + 30, endMinute: 19 * 60, kind: .meal)
        ]
    }

    /// How the weekday set reads on a row: "Every day", "Weekdays", "Mon, Wed, Fri".
    static func describe(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        guard !weekdays.isEmpty else { return "Never" }
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let symbols = calendar.shortWeekdaySymbols
        return weekdays.sorted()
            .compactMap { index in
                let position = index - 1
                return symbols.indices.contains(position) ? symbols[position] : nil
            }
            .joined(separator: ", ")
    }

    /// "7:00 PM – 9:00 PM" for a row's subtitle.
    static func describeTime(_ block: ProtectedBlock, calendar: Calendar = .current) -> String {
        let startOfDay = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .minute, value: block.startMinute, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .minute, value: block.endMinute, to: startOfDay) ?? startOfDay
        return "\(TimeFormat.time(start)) – \(TimeFormat.time(end))"
    }
}
