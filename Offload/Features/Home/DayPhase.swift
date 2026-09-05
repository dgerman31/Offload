import Foundation

/// What time of day it is, in the only sense the app cares about: *what you need from it right
/// now*.
///
/// Home used to be one screen that tried to serve every hour at once — a plan, a next action, a
/// shutdown prompt, habits, groceries, projects — reordered slightly as the day went on. That's
/// why a day could start well and end in a scroll: at 11pm the screen still offered eleven things
/// to do, and the only one that helped was "stop".
///
/// So Home isn't one screen any more. It's four, and the clock picks. Each one does a single job
/// and shows nothing else:
///
/// - **Morning** — decide the day. The plan, and nothing else.
/// - **Now** — do the thing. One task, full screen.
/// - **Tonight** — close the day out honestly.
/// - **Wind down** — empty your head and put the phone down.
///
/// Everything here is pure and injectable so the boundaries are unit-tested rather than observed
/// by holding the app at 8pm. The two "did you already do this today" inputs are passed in as day
/// keys rather than read from `UserDefaults` in here, which keeps this a function of its arguments
/// — and lets the view observe them with `@AppStorage`, so recording one re-renders immediately.
enum DayPhase: String, CaseIterable, Identifiable, Sendable {
    case morning, midday, evening, night

    var id: String { rawValue }

    /// Matches `WakeTracker.earliestHour` — before this you're not up, you're still up.
    static let morningStartHour = 5
    static let middayStartHour = 12
    /// Deliberately the same hour `EveningShutdown` opens at. There was no reason for the app to
    /// hold two different opinions about when the evening starts, and it held them for a while.
    static let eveningStartHour = EveningShutdown.opensAfterHour
    static let nightStartHour = 22

    /// The three phases that are *rituals* — they have a beginning, a job, and an end, so they can
    /// take over the screen once and then get out of the way.
    ///
    /// `.midday` is deliberately absent. "Do the next thing" isn't a ritual, it's just the day, and
    /// a screen that took over every time you opened the app between noon and eight would be an
    /// obstacle rather than a prompt. It's still there on demand.
    static let ritualPhases: [DayPhase] = [.morning, .evening, .night]

    var isRitual: Bool { Self.ritualPhases.contains(self) }

    /// Which rituals have already had their turn today.
    ///
    /// One key holding a day stamp and a list, rather than a flag per phase: it resets by day the
    /// same way every other once-a-day mark in the app does, and "which of today's rituals are
    /// done" is one fact rather than three.
    nonisolated static let handledKey = "offload.dayPhase.handled"

    static func handled(now: Date = Date(), calendar: Calendar = .current,
                        defaults: UserDefaults = .standard) -> Set<DayPhase> {
        let raw = defaults.string(forKey: handledKey) ?? ""
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == dayKey(now, calendar: calendar) else { return [] }
        return Set(parts[1].split(separator: ",").compactMap { DayPhase(rawValue: String($0)) })
    }

    static func isHandled(_ phase: DayPhase, now: Date = Date(), calendar: Calendar = .current,
                          defaults: UserDefaults = .standard) -> Bool {
        handled(now: now, calendar: calendar, defaults: defaults).contains(phase)
    }

    /// Record that a ritual has had its turn — whether you did the thing or waved it away.
    ///
    /// Both count, deliberately. A prompt you dismissed and a prompt you acted on have the same
    /// answer to "should this take over the screen again in ten minutes", and that answer is no.
    static func markHandled(_ phase: DayPhase, now: Date = Date(), calendar: Calendar = .current,
                            defaults: UserDefaults = .standard) {
        var set = handled(now: now, calendar: calendar, defaults: defaults)
        set.insert(phase)
        let list = set.map(\.rawValue).sorted().joined(separator: ",")
        defaults.set("\(dayKey(now, calendar: calendar))|\(list)", forKey: handledKey)
    }

    /// The ritual to put in front of someone opening the app right now, or nil — which it usually is.
    ///
    /// Everything else lives on the Home screen proper; this is only for the three moments a day
    /// that genuinely want the whole screen.
    static func pendingRitual(
        now: Date = Date(),
        plannedDay: String = "",
        closedDay: String = "",
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> DayPhase? {
        let phase = current(now: now, plannedDay: plannedDay, closedDay: closedDay, calendar: calendar)
        guard phase.isRitual else { return nil }
        guard !isHandled(phase, now: now, calendar: calendar, defaults: defaults) else { return nil }
        return phase
    }

    /// Where the day's "I've decided the plan" mark is kept. A day key, like every other
    /// once-a-day flag in the app, so "have I done this today" stays a question about the
    /// calendar rather than about elapsed hours.
    nonisolated static let plannedDayKey = "offload.dayPhase.plannedDay"

    /// The phase for a given moment.
    ///
    /// Two of the four boundaries are decisions rather than hours, which is the point:
    ///
    /// - Morning's job is to settle the day, so **morning ends when the day is settled** — not at
    ///   noon. Plan at 6:40 and the app moves on with you.
    /// - Evening's job is the shutdown, so **closing the day out ends the evening**. Finish at
    ///   8:15 and you get the wind-down screen, not a second invitation to review a day you've
    ///   already reviewed.
    ///
    /// The clock still provides the outer bounds, so neither decision can strand you in a phase.
    static func current(
        now: Date = Date(),
        plannedDay: String = "",
        closedDay: String = "",
        calendar: Calendar = .current
    ) -> DayPhase {
        let hour = calendar.component(.hour, from: now)
        let today = dayKey(now, calendar: calendar)
        if hour >= nightStartHour || hour < morningStartHour { return .night }
        if hour >= eveningStartHour { return closedDay == today ? .night : .evening }
        if hour >= middayStartHour { return .midday }
        return plannedDay == today ? .midday : .morning
    }

    static func dayKey(_ now: Date, calendar: Calendar = .current) -> String {
        WakeTracker.dayKey(now, calendar: calendar)
    }

    /// The line offered on Home when a ritual is available on demand rather than taking over.
    var invitation: String {
        switch self {
        case .morning: return "Plan the day"
        case .midday:  return "One thing at a time"
        case .evening: return "Close out the day"
        case .night:   return "Wind down"
        }
    }

    /// The navigation title. Short enough to sit inline, and named for what you're doing rather
    /// than what hour it is — "Now" is a job, "Afternoon" is a fact.
    var title: String {
        switch self {
        case .morning: return "Morning"
        case .midday:  return "Now"
        case .evening: return "Tonight"
        case .night:   return "Wind down"
        }
    }

    var symbol: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .midday:  return "target"
        case .evening: return "moon.stars.fill"
        case .night:   return "bed.double.fill"
        }
    }
}
