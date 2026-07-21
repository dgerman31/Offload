import Foundation
import GRDB

/// The task mutations every screen shares. Previously each store hand-rolled its own
/// `toggleComplete`, which meant a fix (like spawning the next occurrence of a recurring
/// task) had to be repeated in four places — or, in practice, wasn't.
enum TaskActions {

    /// Snooze presets offered in swipe actions and the edit sheet.
    enum Snooze: String, CaseIterable, Identifiable, Sendable {
        case laterToday = "Later today"
        case tonight = "Tonight"
        case tomorrow = "Tomorrow"
        case nextWeek = "Next week"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .laterToday: return "clock.arrow.circlepath"
            case .tonight:    return "moon.fill"
            case .tomorrow:   return "sun.horizon.fill"
            case .nextWeek:   return "calendar.badge.clock"
            }
        }

        /// Resolve to a concrete moment. Pure, so the arithmetic is unit-testable.
        func date(from now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .laterToday:
                return calendar.date(byAdding: .hour, value: 3, to: now)
            case .tonight:
                // 8pm today, or 8pm tomorrow if it's already past.
                let today8 = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)
                if let today8, today8 > now { return today8 }
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
                return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow)
            case .tomorrow:
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            case .nextWeek:
                guard let week = calendar.date(byAdding: .day, value: 7, to: now) else { return nil }
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: week)
            }
        }
    }

    /// Complete or reopen a task. Completing a **recurring** task also inserts its next
    /// occurrence, in the same transaction, so the habit survives being done.
    /// Returns the newly created follow-up, if any, so the UI can mention it.
    @discardableResult
    static func toggleComplete(
        _ item: TaskItem,
        db: AppDatabase = .shared,
        now: Date = Date()
    ) async -> TaskItem? {
        var updated = item
        let nowCompleted = updated.status != "completed"
        updated.status = nowCompleted ? "completed" : "open"
        updated.completedAt = nowCompleted ? ISO8601DateFormatter().string(from: now) : nil

        let follow = nowCompleted ? Recurrence.nextInstance(of: item, completedAt: now) : nil
        let toSave = updated
        let toInsert = follow

        try? await db.dbQueue.write { database in
            try toSave.update(database)
            if let toInsert { try toInsert.insert(database) }
        }
        return follow
    }

    /// Cycle open → in progress → completed. The schema has always had `in_progress`; this is
    /// what finally makes it reachable, so "started but not finished" stops looking like
    /// "untouched".
    static func advanceStatus(_ item: TaskItem, db: AppDatabase = .shared, now: Date = Date()) async {
        // Finishing goes through toggleComplete so recurring tasks still spawn their next one.
        if item.status == "in_progress" {
            _ = await toggleComplete(item, db: db, now: now)
            return
        }
        var updated = item
        if item.status == "open" {
            updated.status = "in_progress"
        } else {
            updated.status = "open"
            updated.completedAt = nil
        }
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Push a task's due date out. Keeps it visible and honest rather than hiding work.
    static func snooze(
        _ item: TaskItem,
        _ preset: Snooze,
        db: AppDatabase = .shared,
        now: Date = Date()
    ) async {
        guard let date = preset.date(from: now) else { return }
        var updated = item
        updated.dueDate = DueDate.canonicalString(from: date)
        updated.dueDateConfidence = 1.0   // the user said so
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Park a task as blocked on someone else. "Waiting on Sarah" is a real state — it isn't
    /// done, but it also isn't yours to act on, and lumping it in with your live work is what
    /// makes a list feel heavier than it is.
    static func setWaiting(_ item: TaskItem, on person: String?, db: AppDatabase = .shared) async {
        var updated = item
        updated.status = "waiting"
        if let person, !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Merge into the existing people list rather than replacing it.
            let existing = People.decode(item.people)
            updated.people = People.encode(existing + [person])
        }
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Unblock — back into the live list.
    static func clearWaiting(_ item: TaskItem, db: AppDatabase = .shared) async {
        guard item.status == "waiting" else { return }
        var updated = item
        updated.status = "open"
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Copy a task as a fresh, open one — for the things you do again and again but that
    /// aren't worth a formal recurrence rule.
    static func duplicate(_ item: TaskItem, db: AppDatabase = .shared) async {
        var copy = item
        copy.id = UUID().uuidString
        copy.status = "open"
        copy.completedAt = nil
        copy.createdAt = ISO8601DateFormatter().string(from: Date())
        copy.calendarEventId = nil
        let toInsert = copy
        try? await db.dbQueue.write { try toInsert.insert($0) }
    }

    /// Bulk operations for multi-select. One transaction, so a long list doesn't half-apply.
    static func completeAll(_ items: [TaskItem], db: AppDatabase = .shared, now: Date = Date()) async {
        let stamp = ISO8601DateFormatter().string(from: now)
        let updates = items.filter { $0.status != "completed" }.map { item -> TaskItem in
            var copy = item
            copy.status = "completed"
            copy.completedAt = stamp
            return copy
        }
        let followUps = items.compactMap { Recurrence.nextInstance(of: $0, completedAt: now) }
        try? await db.dbQueue.write { database in
            for item in updates { try item.update(database) }
            for follow in followUps { try follow.insert(database) }
        }
    }

    static func deleteAll(_ items: [TaskItem], db: AppDatabase = .shared) async {
        let updates = items.map { item -> TaskItem in
            var copy = item
            copy.deleted = true
            return copy
        }
        try? await db.dbQueue.write { database in
            for item in updates { try item.update(database) }
        }
    }

    static func snoozeAll(_ items: [TaskItem], _ preset: Snooze, db: AppDatabase = .shared, now: Date = Date()) async {
        guard let date = preset.date(from: now) else { return }
        let stamp = DueDate.canonicalString(from: date)
        let updates = items.map { item -> TaskItem in
            var copy = item
            copy.dueDate = stamp
            copy.dueDateConfidence = 1.0
            return copy
        }
        try? await db.dbQueue.write { database in
            for item in updates { try item.update(database) }
        }
    }

    static func delete(
        _ item: TaskItem,
        db: AppDatabase = .shared,
        calendar: any CalendarWriting = EventKitCalendarWriter()
    ) async {
        var updated = item
        updated.deleted = true
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
        // If this task put a real event on the calendar, erasing the task erases the event too —
        // otherwise it lingers on the system calendar with no way to reach it. Only the app's own
        // event (the one we created and linked) is touched; events the user made elsewhere aren't.
        if let eventId = item.calendarEventId {
            _ = await calendar.deleteEvent(id: eventId)
        }
    }

    /// Insert a task the user typed by hand (no AI involved).
    static func create(_ item: TaskItem, db: AppDatabase = .shared) async {
        try? await db.dbQueue.write { try item.insert($0) }
    }
}
