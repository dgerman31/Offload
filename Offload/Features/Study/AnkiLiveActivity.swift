import Foundation
import ActivityKit

/// The app's side of the Anki bar on the Lock Screen.
///
/// ### What went wrong last time, and the rule that comes out of it
///
/// The scroll timer's Live Activity never appeared, and the reason is a rule worth stating plainly:
/// **iOS will not let an app *start* a Live Activity from the background.** That one was requested
/// from inside a Shortcuts-triggered App Intent, with the app woken for a second or two and never
/// foregrounded — so `Activity.request` was refused every time, silently, while the notifications it
/// sat beside worked fine. It looked like a broken widget. It was a lifecycle mistake.
///
/// Updating an existing activity from the background is fine, and that asymmetry is the whole
/// design here:
///
/// - **Start** only when `canStart` is true, which callers set only in the foreground.
/// - **Update** from anywhere — a background refresh, a fetch, a scene change.
/// - **End** the moment the queue is clear or Anki's day rolls over.
///
/// So the bar appears the first time you open Offload with cards due, and then keeps itself current
/// without you opening anything again.
@MainActor
enum AnkiLiveActivity {

    static var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Bring the Lock Screen into line with what we know.
    ///
    /// - Parameter canStart: whether a *new* activity may be requested. Only true in the foreground.
    ///   Passing true from the background doesn't crash — it just quietly fails, which is precisely
    ///   the failure this exists to stop being invisible.
    static func sync(_ snapshot: AnkiSnapshot?, enabled: Bool, canStart: Bool, now: Date = Date()) async {
        guard enabled, let snapshot, !snapshot.isExpired(now: now), !snapshot.isClear else {
            await end()
            return
        }

        let state = AnkiActivityAttributes.ContentState(
            done: snapshot.today.reviewsDone,
            remaining: snapshot.dueRemaining,
            newRemaining: snapshot.today.newRemaining,
            minutesLeft: snapshot.minutesLeft(),
            updatedAt: snapshot.generated ?? now
        )
        // Stale after the rollover whatever happens, so a forgotten activity can't sit on the Lock
        // Screen overnight showing a finished day.
        let content = ActivityContent(state: state, staleDate: snapshot.expiry)

        let existing = Activity<AnkiActivityAttributes>.activities
        if !existing.isEmpty {
            for activity in existing { await activity.update(content) }
            return
        }

        guard canStart else { return }   // background: updating is allowed, starting is not
        guard isAvailable else {
            Log.app.error("Live Activities are disabled for Offload — no Anki bar on the Lock Screen")
            return
        }
        do {
            _ = try Activity.request(
                attributes: AnkiActivityAttributes(deck: snapshot.deck),
                content: content,
                pushType: nil
            )
            Log.app.info("Started the Anki Live Activity (now \(Activity<AnkiActivityAttributes>.activities.count, privacy: .public) active)")
        } catch {
            Log.app.error("Could not start the Anki Live Activity: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    static func end() async {
        for activity in Activity<AnkiActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
