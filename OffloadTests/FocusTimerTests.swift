import Testing
import Foundation
@testable import Offload

/// The focus timer's rules, tested against the value type rather than the running clock.
///
/// `FocusTimer` itself is a main-actor singleton wired to `UserDefaults`, notifications and
/// ActivityKit — none of which belongs in a unit test. What matters is that the countdown is
/// **derived from a deadline** rather than counted, which is what makes it survive the app being
/// suspended, and that's a property of `FocusSessionState` plus the arithmetic over it.
struct FocusTimerTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        phase: FocusActivityAttributes.Phase = .focus,
        minutes: Int = 25,
        paused: TimeInterval? = nil,
        awaitingStart: Bool = false,
        runningSince: Date? = nil,
        banked: TimeInterval = 0,
        blocks: Int = 0
    ) -> FocusSessionState {
        let seconds = TimeInterval(minutes * 60)
        return FocusSessionState(
            taskId: "t", taskTitle: "Enter REDCap data", category: "Work",
            phase: phase,
            endsAt: start.addingTimeInterval(seconds),
            phaseSeconds: seconds,
            pausedRemaining: paused,
            awaitingStart: awaitingStart,
            runningSince: runningSince,
            focusBanked: banked,
            completedBlocks: blocks,
            plannedMinutes: 240,
            startedAt: start
        )
    }

    /// The countdown, exactly as `FocusTimer.remaining` computes it. Duplicated here rather than
    /// reached for through the singleton, so the rule is asserted without a main-actor instance.
    private func remaining(_ s: FocusSessionState, at now: Date) -> TimeInterval {
        if let paused = s.pausedRemaining { return max(0, paused) }
        return max(0, s.endsAt.timeIntervalSince(now))
    }

    @Test("Time passes while the app isn't running, because the deadline is wall-clock")
    func deadlineSurvivesSuspension() {
        let s = session(minutes: 25)
        // The old implementation decremented a counter on a one-second `Task.sleep`, so ten
        // minutes of suspension advanced it by nothing at all. Here nothing needs to have run.
        #expect(remaining(s, at: start) == 25 * 60)
        #expect(remaining(s, at: start.addingTimeInterval(600)) == 15 * 60)
        #expect(remaining(s, at: start.addingTimeInterval(25 * 60)) == 0)
        // And past the deadline it floors rather than going negative.
        #expect(remaining(s, at: start.addingTimeInterval(9999)) == 0)
    }

    @Test("A paused session holds its countdown regardless of the clock")
    func pausedHolds() {
        let s = session(minutes: 25, paused: 12 * 60)
        #expect(remaining(s, at: start) == 12 * 60)
        #expect(remaining(s, at: start.addingTimeInterval(3600)) == 12 * 60)
    }

    @Test("Progress runs 0 to 1 across the phase")
    func progress() {
        let s = session(minutes: 20)
        func progress(at now: Date) -> Double {
            min(1, max(0, 1 - remaining(s, at: now) / s.phaseSeconds))
        }
        #expect(progress(at: start) == 0)
        #expect(progress(at: start.addingTimeInterval(600)) == 0.5)
        #expect(progress(at: start.addingTimeInterval(1200)) == 1)
    }

    @Test("The clock reads as minutes, and grows an hours field only when it needs one")
    func clockFormatting() {
        #expect(FocusTimerTests.clock(0) == "0:00")
        #expect(FocusTimerTests.clock(65) == "1:05")
        #expect(FocusTimerTests.clock(25 * 60) == "25:00")
        // A 90-minute block should say 1:30:00, not 90:00.
        #expect(FocusTimerTests.clock(90 * 60) == "1:30:00")
    }

    /// Mirrors `FocusTimer.clock`.
    static func clock(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: The pomodoro cadence

    /// Which break follows block `n`, using the same rule `FocusTimer.advance` applies.
    private func breakAfter(block: Int) -> FocusActivityAttributes.Phase {
        block > 0 && block % FocusTimer.blocksPerLongBreak == 0 ? .longBreak : .shortBreak
    }

    @Test("Every fourth block earns a long break")
    func longBreakCadence() {
        #expect(breakAfter(block: 1) == .shortBreak)
        #expect(breakAfter(block: 2) == .shortBreak)
        #expect(breakAfter(block: 3) == .shortBreak)
        #expect(breakAfter(block: 4) == .longBreak)
        #expect(breakAfter(block: 5) == .shortBreak)
        #expect(breakAfter(block: 8) == .longBreak)
    }

    @Test("A break is a break and focus isn't")
    func phaseClassification() {
        #expect(FocusActivityAttributes.Phase.focus.isBreak == false)
        #expect(FocusActivityAttributes.Phase.shortBreak.isBreak)
        #expect(FocusActivityAttributes.Phase.longBreak.isBreak)
        #expect(FocusActivityAttributes.Phase.focus.label == "Focus")
    }

    // MARK: Focus banking — what feeds learned effort estimates

    /// Mirrors `FocusTimer.bankFocus`: close out the running stretch at a given moment.
    private func banked(_ s: FocusSessionState, at moment: Date) -> TimeInterval {
        guard let since = s.runningSince else { return s.focusBanked }
        return s.focusBanked + max(0, moment.timeIntervalSince(since))
    }

    @Test("Focus time accumulates across pauses rather than restarting")
    func focusAccumulates() {
        // Ten minutes already banked from an earlier stretch, five more running.
        let s = session(runningSince: start, banked: 600)
        #expect(banked(s, at: start.addingTimeInterval(300)) == 900)
    }

    @Test("A break banks no focus time")
    func breaksDontCount() {
        // `runningSince` is cleared when a break begins, so time spent on one can never be
        // recorded as work — which matters because this number is what teaches the planner how
        // long a task really takes.
        let s = session(phase: .shortBreak, runningSince: nil, banked: 1500)
        #expect(banked(s, at: start.addingTimeInterval(300)) == 1500)
    }

    @Test("Overrun past the deadline isn't counted as focus")
    func banksOnlyToTheDeadline() {
        // `reconcile` banks at `endsAt`, not at the moment it happens to notice. A phone left in
        // a pocket for an hour after a block ended must not record an hour of work.
        let s = session(minutes: 25, runningSince: start)
        #expect(banked(s, at: s.endsAt) == 25 * 60)
    }

    @Test("The planned figure is the task's estimate, not the block length")
    func plannedIsTheTaskEstimate() {
        // A four-hour task worked in 25-minute pomodoros is still a four-hour estimate, and
        // that's the only comparison `TaskSessionLog.drift` can learn anything from.
        let s = session(minutes: 25)
        #expect(s.plannedMinutes == 240)
        #expect(s.phaseSeconds == 25 * 60)
    }

    // MARK: The Live Activity's view of it

    @Test("The Lock Screen gets a window to count down against, derived from the deadline")
    func activityStateWindow() {
        let s = session(minutes: 25)
        let state = FocusActivityAttributes.ContentState(
            phase: s.phase,
            phaseStart: s.endsAt.addingTimeInterval(-s.phaseSeconds),
            phaseEnd: s.endsAt,
            pausedRemaining: s.pausedRemaining,
            completedBlocks: s.completedBlocks,
            awaitingStart: s.awaitingStart
        )
        #expect(state.phaseStart == start)
        #expect(state.phaseEnd == start.addingTimeInterval(25 * 60))
        #expect(state.isRunning)
        #expect(state.isPaused == false)
    }

    @Test("Paused and awaiting-start both read as not running")
    func activityRunningStates() {
        func state(paused: TimeInterval?, awaiting: Bool) -> FocusActivityAttributes.ContentState {
            FocusActivityAttributes.ContentState(
                phase: .focus, phaseStart: start, phaseEnd: start.addingTimeInterval(1500),
                pausedRemaining: paused, completedBlocks: 0, awaitingStart: awaiting)
        }
        #expect(state(paused: 300, awaiting: false).isRunning == false)
        #expect(state(paused: 300, awaiting: false).isPaused)
        #expect(state(paused: 1500, awaiting: true).isRunning == false)
        #expect(state(paused: nil, awaiting: false).isRunning)
    }

    @Test("A session round-trips through storage, so a killed app can pick it back up")
    func statePersists() {
        let s = session(minutes: 25, runningSince: start, banked: 300, blocks: 2)
        let data = try! JSONEncoder().encode(s)
        let restored = try! JSONDecoder().decode(FocusSessionState.self, from: data)
        #expect(restored == s)
        // The deadline is absolute, so a session decoded an hour later is still correct — it
        // simply finds its phase has ended.
        #expect(remaining(restored, at: start.addingTimeInterval(3600)) == 0)
    }
}
