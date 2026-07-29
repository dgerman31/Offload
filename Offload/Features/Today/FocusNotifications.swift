import Foundation
import UserNotifications

/// The alert that fires when a focus block or a break runs out.
///
/// This is what makes a backgrounded timer usable rather than merely correct. `FocusTimer` keeps
/// perfect time with the app suspended — but nothing would *tell* you the block ended, so you'd
/// find out whenever you next happened to look. One notification, scheduled at the deadline and
/// re-armed on every state change.
///
/// Deliberately kept out of `NotificationSync`: that reconciles the whole task set and clears
/// anything it doesn't recognize, so a focus alert living there would be swept away by the next
/// task write. Its own identifier, its own lifecycle.
enum FocusNotifications {
    static let identifier = "offload.focus.phase-end"

    /// Cancel and (if the session is running) re-schedule. Called after every change to the
    /// session, because almost every change moves the deadline: pausing, resuming, skipping a
    /// phase, and finishing one all land somewhere different.
    static func reschedule(for session: FocusTimer.Session?) {
        cancel()
        guard let session, session.pausedRemaining == nil, !session.awaitingStart else { return }
        let interval = session.endsAt.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        switch session.phase {
        case .focus:
            content.title = "Block done"
            // The task's title is the user's own text. It's on their Lock Screen either way, and
            // a notification that doesn't say what finished is useless — but it stays out of the
            // log, which is where the privacy rule actually bites.
            content.body = "\(session.taskTitle) — time for a break."
        case .shortBreak:
            content.title = "Break's over"
            content.body = "Ready to get back to \(session.taskTitle)?"
        case .longBreak:
            content.title = "Long break's over"
            content.body = "Ready to get back to \(session.taskTitle)?"
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Log.notifications.error("Focus alert not scheduled: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
