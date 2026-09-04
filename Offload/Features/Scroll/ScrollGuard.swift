import Foundation

/// The escalation ladder for a scrolling session.
///
/// ### What this is for
///
/// The problem isn't that you open Instagram. It's that twenty minutes disappear without you ever
/// deciding to spend them — the whole design of a feed is to remove the moment where you'd notice.
/// So this doesn't block anything. It *reinstates the moment*: at one minute a silent witness
/// appears, and from there the app gets steadily harder to ignore until you've made an actual
/// decision, either way.
///
/// ### Why the first minute is free
///
/// A tool that punishes a thirty-second check is a tool you switch off inside a week, and a
/// switched-off tool helps nobody. The grace period is the thing that keeps the rest usable.
///
/// ### What iOS makes possible
///
/// No app can see what other app you're in — there's no foreground-app API, and reading another
/// app's screen is out of the question. The only official route is Screen Time (`FamilyControls`),
/// which needs an entitlement a free Apple ID can't hold. So the *sensor* is a Shortcuts personal
/// automation you set up yourself — "when Instagram is opened, run this" — and everything below is
/// what happens once it fires. See `DOOMSCROLL.md` for the version this becomes with a paid
/// account.
///
/// Every rule here is pure and injectable, because a ladder whose timings can only be checked by
/// actually scrolling Instagram for twenty minutes is a ladder that never gets checked.
enum ScrollGuard {

    // MARK: The ladder

    /// Free. Nothing happens, nothing is recorded against you.
    static let graceSeconds: TimeInterval = 60
    /// The first nudge. Late enough that a genuine glance never sees it.
    static let firstNudgeSeconds: TimeInterval = 120
    /// From here it's a steady drumbeat rather than a single tap.
    static let steadyFromSeconds: TimeInterval = 240
    static let steadyCadence: TimeInterval = 60
    /// From here the copy stops being about time and starts being about what the time cost.
    static let costFromSeconds: TimeInterval = 360
    /// From here it is deliberately hard to ignore.
    static let relentlessFromSeconds: TimeInterval = 600
    static let relentlessCadence: TimeInterval = 45

    /// iOS allows 64 pending local notifications per app, and task reminders already claim up to
    /// 40 of them. This is the scroll ladder's share — enough to cover roughly eighteen minutes,
    /// which is well past the point where the message has landed or never will.
    static let maxNudges = 18

    /// If the "Instagram was closed" automation never fires — it's optional, and people forget to
    /// set it up — the session ends itself rather than nagging into the evening.
    static let autoEndSeconds: TimeInterval = 1800

    /// Which rung of the ladder a given elapsed time sits on. `nil` inside the grace period.
    enum Beat: String, Sendable, CaseIterable {
        /// A light tap on the shoulder.
        case nudge
        /// Naming what you left open.
        case push
        /// The same minutes, priced in work.
        case cost
        /// Short, frequent, and impossible to read past.
        case relentless
    }

    static func beat(atElapsed seconds: TimeInterval) -> Beat? {
        switch seconds {
        case ..<firstNudgeSeconds:      return nil
        case ..<steadyFromSeconds:      return .nudge
        case ..<costFromSeconds:        return .push
        case ..<relentlessFromSeconds:  return .cost
        default:                        return .relentless
        }
    }

    /// One scheduled interruption.
    struct Nudge: Equatable, Sendable {
        var offset: TimeInterval
        var beat: Beat
    }

    /// Every interruption for a session, computed up front.
    ///
    /// Up front, because by the time the second one is due the app will have been suspended for
    /// minutes — nothing of ours is running to schedule it. The whole ladder goes into
    /// `UNUserNotificationCenter` at the moment the session starts, and is torn down wholesale
    /// when it ends.
    static func schedule(limit: Int = maxNudges) -> [Nudge] {
        var offsets: [TimeInterval] = [firstNudgeSeconds]
        var t = steadyFromSeconds
        while offsets.count < limit, t <= autoEndSeconds {
            offsets.append(t)
            // The cadence tightens as it goes: the interval is chosen by where we *are*, not where
            // we're going, so the step from 9 to 10 minutes is the last slow one.
            t += (t >= relentlessFromSeconds ? relentlessCadence : steadyCadence)
        }
        return offsets.prefix(limit).compactMap { offset in
            beat(atElapsed: offset).map { Nudge(offset: offset, beat: $0) }
        }
    }

    // MARK: Priced in work

    /// Roughly how many Anki cards fit in a stretch of time.
    ///
    /// Eight seconds a card — a mature-card review, not a new one being learned. Deliberately a
    /// round, slightly conservative number: the point is to make a quantity of minutes feel like
    /// something, not to be an estimate anybody could argue with.
    static let secondsPerCard: TimeInterval = 8

    static func cards(inSeconds seconds: TimeInterval) -> Int {
        max(0, Int(seconds / secondsPerCard))
    }

    static func minutes(_ seconds: TimeInterval) -> Int {
        max(0, Int(seconds / 60))
    }

    // MARK: The off switch

    /// Deliberately easy to reach: on the Lock Screen bar, on every notification, and in Settings.
    ///
    /// The instinct is to make this hard — a commitment device you can't wriggle out of. But an
    /// interruption you can't stop is one you solve by deleting the app, and then it helps you
    /// never again. Cheap to silence for an hour, impossible to forget you silenced it.
    nonisolated static let enabledKey = "offload.scrollGuard.enabled"
    nonisolated static let snoozedUntilKey = "offload.scrollGuard.snoozedUntil"
    nonisolated static let startedAtKey = "offload.scrollGuard.startedAt"
    nonisolated static let dayTotalKey = "offload.scrollGuard.dayTotal"
    nonisolated static let dayTotalDayKey = "offload.scrollGuard.dayTotalDay"

    /// How long the quiet lasts. Named durations rather than a picker: choosing a number is a
    /// decision, and this control exists for moments when you've decided already.
    enum Snooze: String, CaseIterable, Identifiable, Sendable {
        case fifteenMinutes, oneHour, restOfDay

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fifteenMinutes: return "15 minutes"
            case .oneHour:        return "An hour"
            case .restOfDay:      return "Rest of today"
            }
        }

        var shortLabel: String {
            switch self {
            case .fifteenMinutes: return "15m"
            case .oneHour:        return "1h"
            case .restOfDay:      return "Today"
            }
        }

        func expiry(from now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
            case .oneHour:        return now.addingTimeInterval(60 * 60)
            case .restOfDay:
                // Tomorrow's 4am rather than midnight: the hours either side of midnight are
                // exactly when this is most needed and least welcome, and a "rest of today" that
                // silently re-arms at 00:01 would be a small betrayal.
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
                return calendar.date(bySettingHour: 4, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            }
        }
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Absent means on: someone who has set up the automation has already opted in, and making
        // them opt in a second time inside the app is a way to ship a feature that never runs.
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func snoozedUntil(defaults: UserDefaults = .standard) -> Date? {
        let stamp = defaults.double(forKey: snoozedUntilKey)
        guard stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    static func snooze(_ snooze: Snooze, now: Date = Date(), calendar: Calendar = .current,
                       defaults: UserDefaults = .standard) {
        defaults.set(snooze.expiry(from: now, calendar: calendar).timeIntervalSince1970, forKey: snoozedUntilKey)
    }

    static func clearSnooze(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: snoozedUntilKey)
    }

    static func isSnoozed(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let until = snoozedUntil(defaults: defaults) else { return false }
        return until > now
    }

    /// Whether a session started right now would actually do anything.
    static func isArmed(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults) && !isSnoozed(now: now, defaults: defaults)
    }

    // MARK: Today's total

    /// Minutes scrolled today, so the number exists even before anything is built on top of it.
    /// A day key, like every other once-a-day figure in the app, so it resets without anything
    /// having to run at midnight.
    static func todaySeconds(now: Date = Date(), calendar: Calendar = .current,
                             defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.string(forKey: dayTotalDayKey) == WakeTracker.dayKey(now, calendar: calendar) else { return 0 }
        return defaults.double(forKey: dayTotalKey)
    }

    /// How much of a finished session is honest enough to record, or nil for none of it.
    ///
    /// Two judgements, both about not lying to yourself with your own data. A three-second glance
    /// isn't scrolling, so anything inside the grace period counts for nothing. And past the
    /// auto-end we genuinely don't know when you left — the "Instagram was closed" automation is a
    /// famously unreliable trigger, so a session can sit open until you next launch Offload, hours
    /// later. Recording that as hours of scrolling would make the one honest number in this feature
    /// a fiction, so it's capped at the most we're willing to believe.
    static func recordableLength(_ length: TimeInterval) -> TimeInterval? {
        guard length >= graceSeconds else { return nil }
        return min(length, autoEndSeconds)
    }

    static func addToToday(_ seconds: TimeInterval, now: Date = Date(), calendar: Calendar = .current,
                           defaults: UserDefaults = .standard) {
        guard seconds > 0 else { return }
        let running = todaySeconds(now: now, calendar: calendar, defaults: defaults)
        defaults.set(WakeTracker.dayKey(now, calendar: calendar), forKey: dayTotalDayKey)
        defaults.set(running + seconds, forKey: dayTotalKey)
    }
}
