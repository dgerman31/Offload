import Foundation
import UserNotifications
import GRDB

/// Acting on a reminder without opening the app.
///
/// A notification that can only say "you have a thing" and then make you launch an app, find
/// the task and tap it is doing about a third of its job. Long-press the banner and you can
/// mark it done or push it an hour — which, for the overwhelming majority of reminders, is the
/// entire interaction.
///
/// Handled entirely on-device against the local database; there's no server round trip and it
/// works in Airplane mode.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    static let taskCategory = "offload.task"
    static let completeAction = "offload.action.complete"
    static let snoozeAction = "offload.action.snooze"

    private let db: AppDatabase
    init(db: AppDatabase = .shared) {
        self.db = db
        super.init()
    }

    /// Register the actions a task reminder supports. Called once at launch.
    func register() {
        let complete = UNNotificationAction(
            identifier: Self.completeAction,
            title: "Mark done",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction,
            title: "In an hour",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.taskCategory,
            actions: [complete, snooze],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    // MARK: Delegate

    /// Show reminders even while the app is open — otherwise a due task passes silently just
    /// because you happened to be looking at a different screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        await handle(identifier: identifier, action: action)
    }

    /// Pure-ish routing, separated so the id parsing is testable without a live notification.
    func handle(identifier: String, action: String) async {
        guard let taskId = Self.taskId(from: identifier) else { return }
        // `try?` already flattens the optional fetch result, so one binding is enough.
        guard let found = try? await db.dbQueue.read({ try TaskItem.fetchOne($0, key: taskId) })
        else { return }

        switch action {
        case Self.completeAction:
            _ = await TaskActions.toggleComplete(found, db: db)
        case Self.snoozeAction:
            await TaskActions.snooze(found, .laterToday, db: db)
        default:
            break   // tapping the body just opens the app
        }
        // Whatever changed, the schedule should reflect it immediately.
        await NotificationSync.shared.refresh()
    }

    /// Reminder identifiers are "task-<uuid>"; anything else isn't ours.
    nonisolated static func taskId(from identifier: String) -> String? {
        let prefix = "task-"
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
