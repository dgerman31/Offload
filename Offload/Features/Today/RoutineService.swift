import Foundation
import GRDB

/// Brings routines to life: each day it materialises that day's sessions as real tasks, so
/// they flow through everything else — the timeline, reminders, completion, the mental-load
/// score — exactly like anything you captured. Idempotent, so opening the app ten times a day
/// creates nothing extra.
///
/// A task born from a routine carries a marker in its `metadata` (`routineId` + `routineDay`)
/// so it's never duplicated and so "skip just this one" can find and remove it.
@MainActor
final class RoutineService {
    static let shared = RoutineService()

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    // MARK: Materialisation

    /// Ensure today's routine sessions exist as tasks. Safe to call on every app open.
    func materialize(now: Date = Date(), calendar: Calendar = .current) async {
        let data = try? await db.dbQueue.read { db -> ([Routine], [RoutineException], [TaskItem]) in
            // Every task, deleted included — a routine session the user removed today must not
            // reappear on the next open.
            (try Routine.fetchAll(db),
             try RoutineException.fetchAll(db),
             try TaskItem.fetchAll(db))
        }
        guard let (routines, exceptions, allTasks) = data, !routines.isEmpty else { return }

        let today = calendar.startOfDay(for: now)
        let todayKey = RoutineException.dayKey(today, calendar: calendar)

        // Which (routine, today) tasks already exist — including deleted ones, so a session the
        // user removed today doesn't reappear on the next open.
        let existingToday = Set(allTasks.compactMap { task -> String? in
            let marker = Self.marker(of: task)
            guard let marker, marker.day == todayKey else { return nil }
            return marker.routineId
        })

        // 1. Fixed sessions meeting today.
        let fixed = RoutinePlanner.fixedSessions(routines: routines, exceptions: exceptions,
                                                 on: today, calendar: calendar)

        // 2. Flexible routines whose chosen days include today.
        let week = RoutinePlanner.week(containing: today, calendar: calendar)
        let busyness = Dictionary(uniqueKeysWithValues: week.map { day in
            (calendar.startOfDay(for: day),
             RoutinePlanner.busyness(day: day, fixedRoutines: routines, exceptions: exceptions,
                                     events: [], tasks: allTasks, calendar: calendar))
        })

        var flexibleToday: [RoutinePlanner.Session] = []
        for routine in routines where routine.active && routine.routineKind == .flexible {
            let completed = completedDays(of: routine, in: allTasks, week: week, calendar: calendar)
            let days = RoutinePlanner.flexibleDays(routine: routine, week: week, busynessByDay: busyness,
                                                   completedDays: completed, now: now, calendar: calendar)
            if days.contains(where: { calendar.isDate($0, inSameDayAs: today) }) {
                flexibleToday.append(RoutinePlanner.Session(routine: routine, day: today,
                                                            startMinute: nil, durationMinutes: routine.durationMinutes))
            }
        }

        // 3. Create tasks for any session that doesn't already have one today.
        let toCreate = (fixed + flexibleToday).filter { !existingToday.contains($0.routine.id) }
        guard !toCreate.isEmpty else { return }

        let newTasks = toCreate.map { Self.task(from: $0, today: today, todayKey: todayKey, calendar: calendar) }
        try? await db.dbQueue.write { db in
            for task in newTasks { try task.insert(db) }
        }
        await NotificationSync.shared.refresh(now: now)
    }

    /// Build a task from a session. Fixed sessions are pinned anchors at their time; flexible
    /// ones are all-day flexible work the planner can slot into a free gap.
    static func task(from session: RoutinePlanner.Session, today: Date, todayKey: String,
                     calendar: Calendar) -> TaskItem {
        let routine = session.routine
        let dueDate: String
        let allDay: Bool
        let pinned: Bool
        if let startMinute = session.startMinute {
            let start = calendar.date(byAdding: .minute, value: startMinute, to: today) ?? today
            dueDate = DueDate.canonicalString(from: start)
            allDay = false
            pinned = true      // a class time is fixed — it anchors the day
        } else {
            dueDate = DueDate.canonicalString(from: today)
            allDay = true      // "gym sometime today" — flexible work
            pinned = false
        }
        return TaskItem(
            title: routine.title,
            category: routine.category,
            dueDate: dueDate,
            dueDateConfidence: 1.0,
            effortMinutes: routine.durationMinutes,
            metadata: encodeMarker(routineId: routine.id, day: todayKey),
            dueIsAllDay: allDay,
            pinned: pinned
        )
    }

    // MARK: Skipping

    /// "Practice of Medicine is cancelled Friday." Removes the materialised task for its day and
    /// records an exception so materialisation won't recreate it — this week only.
    func skipThisOccurrence(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) async {
        guard let marker = Self.marker(of: task) else {
            // Not a routine task — a plain delete.
            await TaskActions.delete(task, db: db)
            return
        }
        let exception = RoutineException(routineId: marker.routineId, date: marker.day)
        var removed = task
        removed.deleted = true
        let toSave = removed
        try? await db.dbQueue.write { db in
            try exception.insert(db)
            try toSave.update(db)
        }
        Haptics.light()
        await NotificationSync.shared.refresh(now: now)
    }

    // MARK: Marker helpers

    struct Marker: Equatable { var routineId: String; var day: String }

    static func encodeMarker(routineId: String, day: String) -> String? {
        let dict = ["routineId": routineId, "routineDay": day]
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func marker(of task: TaskItem) -> Marker? {
        guard let json = task.metadata, let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let id = dict["routineId"], let day = dict["routineDay"] else { return nil }
        return Marker(routineId: id, day: day)
    }

    /// Whether a task came from a routine — used to offer "skip this week" instead of delete.
    static func isRoutineTask(_ task: TaskItem) -> Bool { marker(of: task) != nil }

    private func completedDays(of routine: Routine, in tasks: [TaskItem], week: [Date],
                              calendar: Calendar) -> Set<Date> {
        let ids = Set(week.map { RoutineException.dayKey($0, calendar: calendar) })
        var days: Set<Date> = []
        for task in tasks where task.status == "completed" {
            guard let marker = Self.marker(of: task), marker.routineId == routine.id,
                  ids.contains(marker.day) else { continue }
            if let due = DueDate.parse(task.dueDate) { days.insert(calendar.startOfDay(for: due)) }
        }
        return days
    }
}
