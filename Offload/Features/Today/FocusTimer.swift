import Foundation
import SwiftUI

/// The focus timer: one shared, deadline-driven clock that outlives the screen that started it.
///
/// The previous implementation failed three separate ways at once, and all three are worth naming
/// because the fix for each is structural rather than a patch:
///
/// 1. **It counted ticks.** A `Task.sleep(1s)` loop decremented a `remaining` counter, so the
///    countdown only advanced while the app was running. iOS suspends a backgrounded app within
///    seconds; the clock simply stopped, and came back showing whatever it had reached. Here the
///    truth is a wall-clock **deadline** — `remaining` is computed as `endsAt - now`, so the app
///    being suspended, killed, or in a tab you're not looking at makes no difference at all. The
///    ticker that remains only refreshes the ring; a missed tick costs a frame, not a minute.
/// 2. **It was per-view state.** `@State private var session = FocusSession()` meant every screen
///    that could start a timer owned a *different* one, and dismissing the sheet destroyed it. One
///    shared instance now, so the session belongs to the app rather than to a view.
/// 3. **It paused itself.** `.onDisappear { session.pause() }` stopped the clock whenever the
///    sheet went away — which is precisely when a timer is most supposed to keep running.
///
/// On top of that it's now a pomodoro: focus blocks separated by breaks, with a long break every
/// fourth block. A break auto-starts when focus ends (you just earned it), but coming *back* from
/// a break always waits for a tap — the app doesn't get to decide you're ready to work again.
@MainActor
@Observable
final class FocusTimer {
    static let shared = FocusTimer()

    // MARK: Settings

    // `nonisolated` throughout: these are read from `@AppStorage` initializers in Settings and
    // from the widget-facing views, and a plain `static let` on a `@MainActor` type drags main-
    // actor isolation along with it. Same treatment `CaptureService.dedupeThresholdKey` already
    // gets, and for the same reason.
    nonisolated static let focusMinutesKey = "offload.focus.focusMinutes"
    nonisolated static let shortBreakMinutesKey = "offload.focus.shortBreakMinutes"
    nonisolated static let longBreakMinutesKey = "offload.focus.longBreakMinutes"
    nonisolated static let sessionStateKey = "offload.focus.session"

    nonisolated static let defaultFocusMinutes = 25
    nonisolated static let defaultShortBreakMinutes = 5
    nonisolated static let defaultLongBreakMinutes = 15
    /// Focus blocks between long breaks — the classic four.
    nonisolated static let blocksPerLongBreak = 4

    nonisolated static func storedMinutes(_ key: String, fallback: Int,
                                          defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: key)
        return stored > 0 ? stored : fallback
    }

    var focusMinutes: Int { Self.storedMinutes(Self.focusMinutesKey, fallback: Self.defaultFocusMinutes) }
    var shortBreakMinutes: Int { Self.storedMinutes(Self.shortBreakMinutesKey, fallback: Self.defaultShortBreakMinutes) }
    var longBreakMinutes: Int { Self.storedMinutes(Self.longBreakMinutesKey, fallback: Self.defaultLongBreakMinutes) }

    // MARK: State

    /// Everything about a live session — defined at file scope (below) and aliased here, so it's
    /// unambiguously a plain `Sendable` value rather than a type nested in a `@MainActor` class.
    /// It crosses into `FocusLiveActivity` and `FocusNotifications`, and it's persisted, so its
    /// isolation shouldn't depend on where it happens to be declared.
    typealias Session = FocusSessionState

    private(set) var session: Session?
    /// Bumped every second while the app is foreground, purely so SwiftUI redraws the ring. The
    /// countdown does not depend on it.
    private(set) var tick = Date()
    /// Whether the full-screen timer is up. Presentation state, kept here rather than in a view
    /// because the thing that presents it (`RootView`) and the things that ask for it (a context
    /// menu on any tab, the mini bar) have no other object in common — and a session that outlives
    /// every screen needs its presentation to outlive them too.
    var isExpanded = false

    private var ticker: Task<Void, Never>?

    private init() {}

    // MARK: Derived

    var isActive: Bool { session != nil }

    /// Seconds left in the current phase. Computed, never stored — this is the whole trick.
    ///
    /// Measured against `tick` rather than `Date()`, and that's load-bearing for a reason that
    /// isn't about time at all: `@Observable` only re-renders a view when a property the view
    /// *read* changes. `Date()` is invisible to it, so a clock built on it would render once and
    /// then sit frozen while the seconds went by. Reading `tick` — which the ticker bumps every
    /// second — is what registers the dependency, so every surface showing the countdown updates
    /// without each of them having to know the ticker exists.
    ///
    /// Accuracy is unaffected: `tick` is only ever a stand-in for "now", and the deadline it's
    /// subtracted from is still absolute. Commands that must not be a second stale (`pause`,
    /// `reconcile`) take a real `Date()` themselves.
    var remaining: TimeInterval {
        guard let session else { return 0 }
        if let paused = session.pausedRemaining { return max(0, paused) }
        return max(0, session.endsAt.timeIntervalSince(tick))
    }

    var isRunning: Bool {
        guard let session else { return false }
        return session.pausedRemaining == nil && !session.awaitingStart
    }

    var phase: FocusActivityAttributes.Phase { session?.phase ?? .focus }

    /// 0…1 through the current phase.
    var progress: Double {
        guard let session, session.phaseSeconds > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / session.phaseSeconds))
    }

    /// "24:05" — and "1:02:30" once a block is over an hour, rather than "62:30".
    var clock: String {
        let total = Int(remaining.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// Focus time in this session so far, including the stretch currently running.
    var focusedSeconds: TimeInterval {
        guard let session else { return 0 }
        let live = session.runningSince.map { Date().timeIntervalSince($0) } ?? 0
        return session.focusBanked + max(0, live)
    }

    // MARK: Lifecycle

    /// Start a session for `task`. Restarting for a task that's already running is a no-op, so
    /// tapping Focus twice can't reset a clock that's been going for twenty minutes.
    func start(task: TaskItem, focusMinutes: Int? = nil) {
        if let session, session.taskId == task.id { isExpanded = true; return }
        // `endingActivity: false` matters. Both teardown and setup hop through `Task` to reach
        // ActivityKit, and two of them in flight at once can land out of order — the old
        // session's "end" arriving after the new session's "start" would kill the activity that
        // had just been created. `FocusLiveActivity.start` sweeps any leftovers itself, so the
        // teardown here would be redundant even if it were safe.
        if session != nil { end(markingComplete: false, endingActivity: false) }

        let minutes = focusMinutes ?? self.focusMinutes
        let seconds = TimeInterval(max(60, minutes * 60))
        let now = Date()
        session = Session(
            taskId: task.id,
            taskTitle: task.title,
            category: task.category,
            phase: .focus,
            endsAt: now.addingTimeInterval(seconds),
            phaseSeconds: seconds,
            pausedRemaining: nil,
            awaitingStart: false,
            runningSince: now,
            focusBanked: 0,
            completedBlocks: 0,
            // The *task's* estimate, not the block length: a 4-hour task done in 25-minute
            // pomodoros is still a 4-hour estimate, and comparing total focus against it is the
            // only comparison that means anything.
            plannedMinutes: task.effortMinutes ?? minutes,
            startedAt: now
        )
        isExpanded = true
        commit(startingActivity: true)
        startTicking()
        Haptics.success()
    }

    func pause() {
        guard var s = session, s.pausedRemaining == nil, !s.awaitingStart else { return }
        s.pausedRemaining = max(0, s.endsAt.timeIntervalSince(Date()))
        bankFocus(into: &s, at: Date())
        session = s
        commit()
    }

    func resume() {
        guard var s = session, let paused = s.pausedRemaining else { return }
        let now = Date()
        s.endsAt = now.addingTimeInterval(paused)
        s.pausedRemaining = nil
        s.awaitingStart = false
        if s.phase == .focus { s.runningSince = now }
        session = s
        commit()
        startTicking()
    }

    /// Start the phase that's waiting — "Back to it" after a break, or starting a break you
    /// deferred.
    func startNextPhase() {
        guard session?.awaitingStart == true else { return }
        resume()
    }

    /// Skip whatever's running and move straight to the next phase.
    func skipPhase() {
        guard var s = session else { return }
        advance(&s, now: Date(), creditBlock: s.phase == .focus)
        session = s
        commit()
        startTicking()
        Haptics.light()
    }

    /// End the session. `markingComplete` records it as work carried through to the end, which is
    /// what makes it count toward learned effort estimates — an abandoned timer says nothing
    /// about how long the work takes.
    func end(markingComplete: Bool, endingActivity: Bool = true) {
        guard var s = session else { return }
        bankFocus(into: &s, at: Date())
        let focused = Int(s.focusBanked / 60)
        let snapshot = s
        session = nil
        isExpanded = false
        stopTicking()
        UserDefaults.standard.removeObject(forKey: Self.sessionStateKey)
        FocusNotifications.cancel()
        if endingActivity { Task { await FocusLiveActivity.end() } }

        // The running totals the stats screen already reads.
        if focused > 0 {
            let defaults = UserDefaults.standard
            defaults.set(defaults.integer(forKey: Self.totalMinutesKey) + focused, forKey: Self.totalMinutesKey)
            defaults.set(defaults.integer(forKey: Self.sessionCountKey) + 1, forKey: Self.sessionCountKey)
        }

        guard focused > 0 else { return }
        Task {
            // Re-read the task rather than trusting a snapshot taken possibly hours ago.
            guard let task = await TaskSessionLog.task(id: snapshot.taskId) else { return }
            await TaskSessionLog.record(
                task: task,
                plannedMinutes: snapshot.plannedMinutes,
                actualMinutes: focused,
                startedAt: snapshot.startedAt,
                ranToCompletion: markingComplete
            )
        }
    }

    /// The running totals the Insights screen reads. Same keys the old `FocusSession` wrote, so
    /// the minutes already banked carry over rather than resetting to zero on this update.
    nonisolated static let totalMinutesKey = "offload.focus.totalMinutes"
    nonisolated static let sessionCountKey = "offload.focus.sessions"

    // MARK: Time passing

    /// Bring the session up to date with the real clock.
    ///
    /// Called on every tick and, more importantly, whenever the app returns to the foreground —
    /// which is when the interesting case happens: the phase ended twenty minutes ago while the
    /// app was suspended. Deliberately advances **one** phase and no further. Fast-forwarding
    /// through three pomodoros because the app was closed for two hours would be inventing focus
    /// time that never happened.
    func reconcile(now: Date = Date()) {
        guard var s = session, s.pausedRemaining == nil, !s.awaitingStart, now >= s.endsAt else { return }
        // Bank only up to the deadline — time after the phase ended wasn't focus.
        bankFocus(into: &s, at: s.endsAt)
        advance(&s, now: now, creditBlock: s.phase == .focus)
        session = s
        commit()
        Haptics.success()
    }

    /// Move to whatever comes next.
    ///
    /// A break **auto-starts** when focus ends: you've just finished a block and the break is the
    /// point. Coming back from a break never auto-starts — it waits for a tap, because the app
    /// doesn't get to decide you're ready to work again, and a focus block that began while your
    /// phone was in your pocket would be recorded as work you didn't do.
    private func advance(_ s: inout Session, now: Date, creditBlock: Bool) {
        if s.phase == .focus {
            if creditBlock { s.completedBlocks += 1 }
            let isLong = s.completedBlocks > 0 && s.completedBlocks % Self.blocksPerLongBreak == 0
            let minutes = isLong ? longBreakMinutes : shortBreakMinutes
            s.phase = isLong ? .longBreak : .shortBreak
            s.phaseSeconds = TimeInterval(max(60, minutes * 60))
            s.endsAt = now.addingTimeInterval(s.phaseSeconds)
            s.pausedRemaining = nil
            s.awaitingStart = false
            s.runningSince = nil
        } else {
            s.phase = .focus
            s.phaseSeconds = TimeInterval(max(60, focusMinutes * 60))
            s.endsAt = now.addingTimeInterval(s.phaseSeconds)
            s.pausedRemaining = s.phaseSeconds       // held at full, not running
            s.awaitingStart = true
            s.runningSince = nil
        }
    }

    /// Move the currently-running focus stretch into the banked total and close it out.
    private func bankFocus(into s: inout Session, at moment: Date) {
        guard let since = s.runningSince else { return }
        s.focusBanked += max(0, moment.timeIntervalSince(since))
        s.runningSince = nil
    }

    /// The ticker exists only to move `tick` forward so views re-render, and to notice a phase
    /// ending while the app is open. It is emphatically **not** the clock: skipped, delayed, or
    /// cancelled ticks cost a frame, never a second, because the deadline they're measured
    /// against never moves. That's the entire difference from the version this replaced.
    private func startTicking() {
        stopTicking()
        guard isRunning else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.session != nil else { return }
                self.tick = Date()
                self.reconcile()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Persistence and mirrors

    /// Save, re-arm the notification, and push the Lock Screen — the three things that must stay
    /// in step with the session after *every* change, which is why they're one call rather than
    /// three that can be forgotten separately.
    private func commit(startingActivity: Bool = false) {
        persist()
        FocusNotifications.reschedule(for: session)
        let snapshot = session
        let title = snapshot?.taskTitle ?? ""
        let accent = UInt32(Color.Offload.accentHex(for: snapshot?.category))
        Task {
            if startingActivity {
                await FocusLiveActivity.start(taskTitle: title, accentHex: accent, session: snapshot)
            } else {
                await FocusLiveActivity.update(session: snapshot)
            }
        }
    }

    private func persist() {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            UserDefaults.standard.removeObject(forKey: Self.sessionStateKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.sessionStateKey)
    }

    /// Restore a session the app was killed in the middle of, then bring it up to date. Because
    /// the deadline is absolute, a session restored an hour later is still correct — it simply
    /// finds that its phase ended and moves on.
    func restore() {
        guard session == nil,
              let data = UserDefaults.standard.data(forKey: Self.sessionStateKey),
              let saved = try? JSONDecoder().decode(Session.self, from: data)
        else { return }
        session = saved
        reconcile()
        startTicking()
        Log.app.info("Restored a focus session in progress")
    }

    /// Foreground handling: catch up, and resume ticking if the session is live.
    func applicationBecameActive() {
        guard session != nil else { return }
        reconcile()
        tick = Date()
        startTicking()
    }
}

/// A live focus session, in one `Codable` value so restoring after the app is killed is a single
/// decode rather than a pile of loose keys that can disagree with each other.
///
/// File scope rather than nested in `FocusTimer`: this value is persisted, handed to
/// `FocusNotifications`, and passed into `FocusLiveActivity`, so it needs to be plainly
/// `Sendable` without depending on how global-actor isolation does or doesn't reach a type
/// declared inside a `@MainActor` class.
struct FocusSessionState: Codable, Equatable, Sendable {
    var taskId: String
    var taskTitle: String
    var category: String?
    var phase: FocusActivityAttributes.Phase
    /// Wall-clock deadline for the current phase. **The source of truth** — everything else about
    /// the countdown is derived from it, which is what lets the clock survive suspension.
    var endsAt: Date
    /// How long the current phase is in total, for the progress ring.
    var phaseSeconds: TimeInterval
    /// Frozen countdown while paused; `nil` means running.
    var pausedRemaining: TimeInterval?
    /// True when a phase ended and the next is waiting on a tap.
    var awaitingStart: Bool
    /// When the *current* uninterrupted focus stretch began — `nil` during a break or a pause.
    var runningSince: Date?
    /// Focus seconds already banked from stretches that ended (pause, break, phase end).
    var focusBanked: TimeInterval
    /// Completed focus blocks, driving the long-break cadence and the dots.
    var completedBlocks: Int
    /// The task's own estimate when the session started — what `TaskSessionLog` compares against.
    /// Captured up front because the task row can change underneath a session lasting hours.
    var plannedMinutes: Int
    var startedAt: Date
}
