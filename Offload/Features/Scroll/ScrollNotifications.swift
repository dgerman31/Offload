import Foundation
import UserNotifications

/// The ladder, put into `UNUserNotificationCenter` in one go.
///
/// All of it up front, at the moment the session starts, because nothing of ours will be running
/// later — you're inside Instagram and Offload is suspended within seconds. There is no timer to
/// tick, no background task to wake; the only thing that can reach you is a notification the system
/// already holds. So the whole escalation is handed over at once and torn down wholesale when the
/// session ends.
///
/// Its own identifier prefix and its own lifecycle, kept well away from `NotificationSync`, which
/// reconciles the task set and deletes anything it doesn't recognise.
enum ScrollNotifications {
    static let prefix = "offload.scroll."
    static let category = "offload.scroll"
    static let snoozeAction = "offload.scroll.action.snooze"
    static let stopAction = "offload.scroll.action.stop"

    /// Register the two actions every scroll notification carries.
    ///
    /// This is the off switch the user asked to be easy: long-press any nudge and it's quiet for
    /// fifteen minutes, without opening the app, without finding a setting. A notification you can
    /// only dismiss is one you eventually turn off at the system level, and then it's gone for good.
    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(identifier: snoozeAction, title: "Quiet for 15 min", options: []),
                UNNotificationAction(identifier: stopAction, title: "I've stopped", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Schedule the whole ladder for a session starting now.
    static func schedule(startedAt: Date, task: String?, now: Date = Date()) {
        cancel()
        let daySeed = ScrollLines.daySeed(now)
        let center = UNUserNotificationCenter.current()

        for (index, nudge) in ScrollGuard.schedule().enumerated() {
            // Measured from the real start rather than from "now", so a session recovered after a
            // relaunch resumes the ladder where it actually is instead of starting again.
            let fireIn = startedAt.addingTimeInterval(nudge.offset).timeIntervalSince(now)
            guard fireIn > 0 else { continue }

            let context = ScrollLines.Context(
                minutes: ScrollGuard.minutes(nudge.offset),
                cards: ScrollGuard.cards(inSeconds: nudge.offset),
                task: task
            )
            let line = ScrollLines.line(for: nudge.beat, index: index, context: context, daySeed: daySeed)

            let content = UNMutableNotificationContent()
            content.title = line.title
            content.body = line.body
            content.sound = .default
            content.categoryIdentifier = category
            // Breaks through Focus, and it has to: the moment this matters most is the evening,
            // which is exactly when a Do Not Disturb is likeliest to be on.
            content.interruptionLevel = .timeSensitive
            // Grouped, so eighteen of these collapse into one stack on the Lock Screen instead of
            // burying every other notification you have.
            content.threadIdentifier = category

            center.add(UNNotificationRequest(
                identifier: "\(prefix)\(index)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
            )) { error in
                guard let error else { return }
                Log.notifications.error("Scroll nudge not scheduled: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Fire one nudge in a few seconds, so the whole delivery path can be checked without
    /// scrolling Instagram for two minutes.
    ///
    /// This earns its place because of a failure that is otherwise indistinguishable from "the
    /// automation didn't fire": if notifications are denied, or Time Sensitive delivery is off for
    /// Offload, the entire feature is silent and nothing anywhere says so. One test nudge answers
    /// that in five seconds. It carries the real category, so the long-press actions can be tried
    /// out too.
    static func sendTestNudge(after seconds: TimeInterval = 5, now: Date = Date()) {
        let context = ScrollLines.Context(minutes: 2, cards: 15, task: nil)
        let line = ScrollLines.line(for: .nudge, index: 0, context: context, daySeed: ScrollLines.daySeed(now))

        let content = UNMutableNotificationContent()
        content.title = line.title
        content.body = line.body
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = category

        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: testIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        )) { error in
            guard let error else { return }
            Log.notifications.error("Test nudge not scheduled: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    static let testIdentifier = prefix + "test"

    /// Take the whole ladder down. Called when the session ends, when it's snoozed, and when the
    /// guard is switched off — all three have to leave nothing pending, or a nudge arrives twenty
    /// minutes after you stopped and the feature reads as broken.
    static func cancel() {
        let ids = (0..<ScrollGuard.maxNudges).map { "\(prefix)\($0)" } + [testIdentifier]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
