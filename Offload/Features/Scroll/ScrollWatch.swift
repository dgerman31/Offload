import Foundation
import ActivityKit
import GRDB

/// A scrolling session, from the moment the automation says you opened the feed to the moment it
/// says you closed it.
///
/// The session itself is two things: a start date in `UserDefaults` and a stack of pending
/// notifications. Deliberately nothing else — no timer, no background task, no observation. Offload
/// is suspended within seconds of you switching to Instagram, so anything requiring the app to be
/// alive would simply stop. The start date survives being killed, and the ladder is already in the
/// system's hands.
///
/// The Live Activity is a *mirror*, never the source: if Live Activities are off, or the system
/// declines to start one from the background, the notifications are entirely unaffected. That's the
/// right dependency direction — the Lock Screen can fail, the ladder can't.
@MainActor
@Observable
final class ScrollWatch {
    static let shared = ScrollWatch()

    private let defaults: UserDefaults
    private let db: AppDatabase

    /// When the current session began, or nil if nothing is running.
    private(set) var startedAt: Date?
    /// What you left open, resolved once at the start.
    private(set) var task: String?

    init(defaults: UserDefaults = .standard, db: AppDatabase = .shared) {
        self.defaults = defaults
        self.db = db
        let stamp = defaults.double(forKey: ScrollGuard.startedAtKey)
        // Recovered rather than reset: the app being relaunched mid-session is the normal case,
        // not an edge one — you came back to Offload *because* a nudge landed.
        self.startedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    var isRunning: Bool { startedAt != nil }

    func elapsed(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Install the Lock Screen buttons' handler. Called once at launch, like the focus bus.
    func installCommandHandler() {
        ScrollCommandBus.install { [weak self] command in
            guard let self else { return }
            switch command {
            case .snooze: Task { await self.snooze(.fifteenMinutes) }
            case .stop:   Task { await self.stop() }
            }
        }
    }

    // MARK: Starting and stopping

    /// The feed was opened. Called from the Shortcuts automation, via `StartScrollWatchIntent`.
    ///
    /// Idempotent: an automation that fires twice (they do) must not restart the clock, or a long
    /// session would keep resetting to zero and the ladder would never get past its first rung.
    func start(now: Date = Date()) async {
        guard ScrollGuard.isArmed(now: now, defaults: defaults) else { return }
        guard startedAt == nil else { return }

        startedAt = now
        defaults.set(now.timeIntervalSince1970, forKey: ScrollGuard.startedAtKey)
        task = await abandonedTask()

        ScrollNotifications.schedule(startedAt: now, task: task, now: now)
        await startActivity(startedAt: now)
        Log.app.info("Scroll session started")
    }

    /// The feed was closed, or you pressed a button saying so.
    func stop(now: Date = Date()) async {
        guard let startedAt else {
            // Still worth clearing: a session can be left half-torn-down by a crash, and pending
            // nudges from a session nobody remembers are the worst version of this feature.
            ScrollNotifications.cancel()
            await endActivity()
            return
        }
        let length = max(0, now.timeIntervalSince(startedAt))
        // Only sessions that got past the grace period count. A three-second glance is not
        // scrolling, and counting it would make the daily total meaningless.
        if length >= ScrollGuard.graceSeconds {
            ScrollGuard.addToToday(length, now: now, defaults: defaults)
        }
        self.startedAt = nil
        task = nil
        defaults.removeObject(forKey: ScrollGuard.startedAtKey)
        ScrollNotifications.cancel()
        await endActivity()
        Log.app.info("Scroll session ended after \(Int(length), privacy: .public)s")
    }

    /// Quiet for a while, and end whatever's running.
    func snooze(_ snooze: ScrollGuard.Snooze, now: Date = Date()) async {
        ScrollGuard.snooze(snooze, now: now, defaults: defaults)
        await stop(now: now)
        Haptics.success()
    }

    func endSnooze() {
        ScrollGuard.clearSnooze(defaults: defaults)
    }

    func setEnabled(_ enabled: Bool) async {
        ScrollGuard.setEnabled(enabled, defaults: defaults)
        if !enabled { await stop() }
    }

    // MARK: What you put down

    /// The task the feed interrupted — the single most useful thing a nudge can name, because what
    /// a feed actually erases isn't time, it's the memory that you were doing something else.
    ///
    /// Best-effort and quiet: this runs inside a background intent with a second or two of runtime,
    /// so a failure returns nil and the copy falls back to lines that need no task.
    private func abandonedTask() async -> String? {
        let tasks = try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }
        guard let tasks else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let candidates = tasks.filter { task in
            guard task.isPlannable else { return false }
            guard let due = DueDate.parse(task.dueDate) else { return false }
            return due < today || calendar.isDate(due, inSameDayAs: Date())
        }
        return NextBest.pick(from: candidates.isEmpty ? tasks : candidates)?.title
    }

    // MARK: The Lock Screen mirror

    private func startActivity(startedAt: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.app.error("Live Activities are disabled for Offload — no scroll bar on the Lock Screen")
            return
        }
        await endActivity()
        do {
            _ = try Activity.request(
                attributes: ScrollActivityAttributes(startedAt: startedAt),
                content: ActivityContent(
                    state: ScrollActivityAttributes.ContentState(task: task),
                    staleDate: startedAt.addingTimeInterval(ScrollGuard.autoEndSeconds)
                ),
                pushType: nil   // it counts up locally; there is nothing to push
            )
        } catch {
            // Expected to fail sometimes and that's survivable: starting a Live Activity from a
            // background intent isn't guaranteed, and the notifications are the actual feature.
            Log.app.error("Could not start the scroll Live Activity: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func endActivity() async {
        for activity in Activity<ScrollActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Housekeeping on foreground: close out a session that ran past the cap because the "closed"
    /// automation was never set up or didn't fire.
    func sweepStaleSession(now: Date = Date()) async {
        guard let startedAt else { return }
        guard now.timeIntervalSince(startedAt) >= ScrollGuard.autoEndSeconds else { return }
        await stop(now: now)
    }
}
