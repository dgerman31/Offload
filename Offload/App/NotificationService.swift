import Foundation
import UserNotifications

/// Local reminders. Deliberately *local* — no server, no push certificate, nothing leaves the
/// phone, and it works on a free Apple ID. This is what turns Offload from something you have
/// to remember to open into something that reaches you at the right moment.
///
/// Three kinds of nudge, all opt-in:
/// - **Task reminders** at a task's due time.
/// - **Morning brief** — what today looks like, before it starts.
/// - **Evening review** — close the loops, park tomorrow's first thing.
@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    // Preference keys, surfaced in Settings.
    static let remindersEnabledKey = "offload.notifications.reminders"
    static let briefEnabledKey     = "offload.notifications.brief"
    static let briefHourKey        = "offload.notifications.briefHour"
    static let reviewEnabledKey    = "offload.notifications.review"
    static let reviewHourKey       = "offload.notifications.reviewHour"

    static let defaultBriefHour = 8
    static let defaultReviewHour = 21

    /// iOS keeps at most 64 pending local notifications per app; stay well under it and
    /// schedule the soonest work, which is the only part the user can act on anyway.
    private static let maxTaskReminders = 40

    private let center = UNUserNotificationCenter.current()
    private let taskPrefix = "task-"
    private let briefId = "daily-brief"
    private let reviewId = "evening-review"

    // MARK: Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    // MARK: Task reminders

    /// Reconcile pending reminders against the current task list: drop anything completed,
    /// deleted, undated or past, and (re)schedule the rest. Called whenever tasks change, so
    /// editing a due date or ticking something off updates the reminder immediately.
    func syncTaskReminders(tasks: [TaskItem], enabled: Bool, now: Date = Date()) async {
        let pending = await center.pendingNotificationRequests()
        let existingTaskIds = Set(
            pending.map(\.identifier).filter { $0.hasPrefix(taskPrefix) }
        )

        guard enabled, await isAuthorized else {
            if !existingTaskIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(existingTaskIds))
            }
            return
        }

        let wanted = Self.remindableTasks(from: tasks, now: now, limit: Self.maxTaskReminders)
        let wantedIds = Set(wanted.map { taskPrefix + $0.id })

        // Remove reminders that no longer apply.
        let stale = existingTaskIds.subtracting(wantedIds)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }

        // (Re)add the current set — re-adding an existing identifier replaces it, which keeps
        // an edited due time correct without extra bookkeeping.
        for task in wanted {
            guard let due = DueDate.parse(task.dueDate) else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = Self.reminderBody(for: task)
            content.sound = .default
            content.interruptionLevel = task.priority == "high" ? .timeSensitive : .active
            content.threadIdentifier = "offload-tasks"
            // Lets you finish or defer straight from the banner.
            content.categoryIdentifier = NotificationDelegate.taskCategory

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            let request = UNNotificationRequest(
                identifier: taskPrefix + task.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Pure selection (testable): open, non-deleted, future-dated tasks, soonest first.
    nonisolated static func remindableTasks(from tasks: [TaskItem], now: Date, limit: Int) -> [TaskItem] {
        tasks
            .filter { $0.status != "completed" && !$0.deleted }
            .compactMap { task -> (TaskItem, Date)? in
                guard let due = DueDate.parse(task.dueDate), due > now else { return nil }
                return (task, due)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    nonisolated static func reminderBody(for task: TaskItem) -> String {
        if let details = task.descriptionText, !details.isEmpty {
            return String(details.prefix(120))
        }
        var parts: [String] = []
        if let category = task.category { parts.append(category) }
        if let effort = task.effortMinutes { parts.append("~\(effort) min") }
        return parts.isEmpty ? "Due now" : parts.joined(separator: " · ")
    }

    // MARK: Daily brief + evening review

    /// A repeating morning nudge summarising the day. The body is written fresh each time the
    /// app syncs, so it reflects the real state rather than a stale snapshot.
    func scheduleDailyBrief(enabled: Bool, hour: Int, summary: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [briefId])
        guard enabled, await isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your day"
        content.body = summary
        content.sound = .default
        content.threadIdentifier = "offload-brief"

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        try? await center.add(UNNotificationRequest(
            identifier: briefId,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        ))
    }

    func scheduleEveningReview(enabled: Bool, hour: Int) async {
        center.removePendingNotificationRequests(withIdentifiers: [reviewId])
        guard enabled, await isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Close the day"
        content.body = "Tick off what you finished and park anything still on your mind."
        content.sound = .default
        content.threadIdentifier = "offload-review"

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        try? await center.add(UNNotificationRequest(
            identifier: reviewId,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        ))
    }

    /// One-line summary used as the morning brief body.
    nonisolated static func briefSummary(for summary: DaySummary) -> String {
        if summary.overdueCount > 0 {
            return "\(summary.overdueCount) overdue · \(summary.dueTodayCount) due today · \(summary.eventCount) on your calendar."
        }
        if summary.dueTodayCount == 0 && summary.eventCount == 0 {
            return "Nothing scheduled. The day is yours."
        }
        var parts: [String] = []
        if summary.eventCount > 0 { parts.append("\(summary.eventCount) event\(summary.eventCount == 1 ? "" : "s")") }
        if summary.dueTodayCount > 0 { parts.append("\(summary.dueTodayCount) task\(summary.dueTodayCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ") + " today."
    }

    func cancelEverything() {
        center.removeAllPendingNotificationRequests()
    }
}
