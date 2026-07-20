import Foundation
import GRDB

/// Keeps scheduled notifications matched to real data. Reminders are reconciled from the live
/// task list, and the morning brief's body is rewritten with the actual shape of the day, so
/// the nudge you get at 8am reflects the world rather than a snapshot from whenever you last
/// toggled a switch.
///
/// Called on app foreground/background and whenever notification preferences change — cheap
/// enough to run often, since it's one query plus a diff against pending requests.
@MainActor
final class NotificationSync {
    static let shared = NotificationSync()

    private let db: AppDatabase
    private let calendarReader: any CalendarReading

    init(db: AppDatabase = .shared, calendarReader: any CalendarReading = EventKitCalendarReader()) {
        self.db = db
        self.calendarReader = calendarReader
    }

    private var defaults: UserDefaults { .standard }

    /// Reconcile everything. Pass `remindersEnabled` to override the stored preference (used
    /// when a toggle has just flipped and the write may not have landed yet).
    func refresh(remindersEnabled: Bool? = nil, now: Date = Date()) async {
        let service = NotificationService.shared
        let remindersOn = remindersEnabled ?? defaults.bool(forKey: NotificationService.remindersEnabledKey)
        let briefOn = defaults.bool(forKey: NotificationService.briefEnabledKey)

        let tasks = (try? await db.dbQueue.read { db in
            try TaskItem.filter(Column("deleted") == false).fetchAll(db)
        }) ?? []

        await service.syncTaskReminders(tasks: tasks, enabled: remindersOn, now: now)

        guard briefOn else { return }
        // Only touch the calendar when the brief actually needs it.
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let events = await calendarReader.events(from: start, to: end)

        let summary = DayDashboard.summary(tasks: tasks, events: events, now: now)
        var hour = defaults.integer(forKey: NotificationService.briefHourKey)
        if hour == 0 { hour = NotificationService.defaultBriefHour }

        await service.scheduleDailyBrief(
            enabled: true,
            hour: hour,
            summary: NotificationService.briefSummary(for: summary)
        )
    }
}
