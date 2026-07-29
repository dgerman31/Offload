import Foundation
import ActivityKit

/// The app's side of the Lock Screen timer: starts, updates, and ends the Live Activity that
/// `OffloadWidgets` renders.
///
/// Everything here is best-effort by design. A Live Activity is a *mirror* of the session, never
/// its source — the session is a deadline in `FocusTimer` plus a row in `UserDefaults`. So if the
/// user has Live Activities switched off, or the system declines to start one, the timer itself
/// is completely unaffected and the app carries on. That's the right dependency direction: the
/// Lock Screen can fail, the clock can't.
///
/// `ActivityKit` needs no entitlement and no App Group, which matters here — this app is signed
/// with a free Apple ID and can't have either.
///
/// `@MainActor` because it holds the current activity in mutable static state, which strict
/// concurrency would otherwise (correctly) reject, and because every caller is already there.
@MainActor
enum FocusLiveActivity {

    /// Whether the system will let us show one at all. `false` when the user has turned Live
    /// Activities off for Offload in Settings, which is a preference, not an error.
    static var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// The activity this process started, if any. Held rather than looked up each time so an
    /// update can't accidentally address a different one.
    private static var current: Activity<FocusActivityAttributes>?

    static func start(taskTitle: String, accentHex: UInt32, session: FocusTimer.Session?) async {
        guard let session, isAvailable else { return }
        await end()   // never two at once

        let attributes = FocusActivityAttributes(taskTitle: taskTitle, accentHex: accentHex)
        do {
            current = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state(from: session), staleDate: session.endsAt.addingTimeInterval(3600)),
                pushType: nil   // the countdown ticks locally; there is nothing to push
            )
            Log.app.info("Started the focus Live Activity")
        } catch {
            // Shape only. The description here is an ActivityKit error and carries no user
            // content, but the house rule is one rule, not one per call site.
            Log.app.error("Could not start the focus Live Activity: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    static func update(session: FocusTimer.Session?) async {
        guard let activity = current else { return }
        guard let session else { return await end() }
        await activity.update(ActivityContent(state: state(from: session),
                                              staleDate: session.endsAt.addingTimeInterval(3600)))
    }

    static func end() async {
        // Also sweep any activity left behind by a previous launch — the app can be killed while
        // one is live, and a stale timer on the Lock Screen is worse than none.
        for activity in Activity<FocusActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        current = nil
    }

    /// Adopt an activity that survived a relaunch, so the app is updating the one already on
    /// screen instead of stranding it and starting a second.
    static func adoptExisting() {
        current = Activity<FocusActivityAttributes>.activities.first
    }

    private static func state(from session: FocusTimer.Session) -> FocusActivityAttributes.ContentState {
        FocusActivityAttributes.ContentState(
            phase: session.phase,
            // The window the widget counts down against. Derived from the deadline and the phase
            // length rather than stored, so it stays correct across a pause and resume.
            phaseStart: session.endsAt.addingTimeInterval(-session.phaseSeconds),
            phaseEnd: session.endsAt,
            pausedRemaining: session.pausedRemaining,
            completedBlocks: session.completedBlocks,
            awaitingStart: session.awaitingStart
        )
    }
}
