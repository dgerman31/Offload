import Foundation
import GRDB

/// A single task (spec §6 `tasks`). Named `TaskItem` to avoid colliding with
/// Swift Concurrency's `Task`. Hierarchy is via `parentTaskId` (self-FK).
struct TaskItem: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    var descriptionText: String?
    var category: String?
    var priority: String
    var status: String              // open | in_progress | completed | deferred
    var parentTaskId: String?
    var projectId: String?
    var createdAt: String
    var dueDate: String?
    var dueDateConfidence: Double?
    var recurrenceRule: String?     // iCalendar RRULE
    var completedAt: String?
    var deferredUntil: String?
    var contextTags: String?        // JSON array text
    var effortMinutes: Int?
    var energyLevel: String?
    var calendarEventId: String?
    var metadata: String?           // JSON
    var deleted: Bool
    var people: String?             // JSON array of names this task involves

    /// A hard deadline, distinct from `dueDate` ("when I plan to do it"). Conflating the two
    /// is the classic task-app mistake: a due date is not a do date.
    var deadline: String?
    /// True when `dueDate` means a *day* rather than a moment — so a task scheduled for
    /// "Friday" doesn't have to pretend it happens at midnight.
    var dueIsAllDay: Bool
    /// True when a human or a real calendar event fixed this exact time. Pinned times anchor
    /// the day; unpinned ones (the planner's guesses) reflow when the timeline self-heals.
    var pinned: Bool
    /// User-set manual position for drag-to-reorder. Nil = never reordered (falls back to
    /// capture order); lower sorts first within a list.
    var sortOrder: Double?
    /// Set when this task is the schedule block for a planned workout (the Gym tab). Home/Day
    /// show only the title and the time it occupies; tapping the row opens the Gym tab to that
    /// session instead of the normal task detail — the workout's real detail (exercises, sets,
    /// muscle groups) lives only there, never duplicated into the task itself.
    var gymSessionId: String?
    /// What kind of thing this is — see `CaptureKind`. Stored as its raw string so an unknown
    /// value from a future version degrades to a task rather than failing to decode the row.
    ///
    /// This is the column that stops an idea being a chore: `CaptureKind.isSchedulable` is checked
    /// wherever work gets planned, so a row that isn't a task simply never enters the day.
    var kind: String

    /// The typed form. Always use this rather than comparing `kind` strings at a call site.
    var captureKind: CaptureKind { CaptureKind.parse(kind) }

    static let databaseTableName = "tasks"

    enum CodingKeys: String, CodingKey {
        case id, title
        case descriptionText = "description"
        case category, priority, status
        case parentTaskId = "parent_task_id"
        case projectId = "project_id"
        case createdAt = "created_at"
        case dueDate = "due_date"
        case dueDateConfidence = "due_date_confidence"
        case recurrenceRule = "recurrence_rule"
        case completedAt = "completed_at"
        case deferredUntil = "deferred_until"
        case contextTags = "context_tags"
        case effortMinutes = "effort_minutes"
        case energyLevel = "energy_level"
        case calendarEventId = "calendar_event_id"
        case metadata, deleted, people, deadline, pinned
        case dueIsAllDay = "due_is_all_day"
        case sortOrder = "sort_order"
        case gymSessionId = "gym_session_id"
        case kind
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        descriptionText: String? = nil,
        category: String? = nil,
        priority: String = "medium",
        status: String = "open",
        parentTaskId: String? = nil,
        projectId: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        dueDate: String? = nil,
        dueDateConfidence: Double? = nil,
        recurrenceRule: String? = nil,
        completedAt: String? = nil,
        deferredUntil: String? = nil,
        contextTags: String? = nil,
        effortMinutes: Int? = nil,
        energyLevel: String? = nil,
        calendarEventId: String? = nil,
        metadata: String? = nil,
        deleted: Bool = false,
        people: String? = nil,
        deadline: String? = nil,
        dueIsAllDay: Bool = false,
        pinned: Bool = false,
        sortOrder: Double? = nil,
        gymSessionId: String? = nil,
        kind: CaptureKind = .task
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.category = category
        self.priority = priority
        self.status = status
        self.parentTaskId = parentTaskId
        self.projectId = projectId
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.dueDateConfidence = dueDateConfidence
        self.recurrenceRule = recurrenceRule
        self.completedAt = completedAt
        self.deferredUntil = deferredUntil
        self.contextTags = contextTags
        self.effortMinutes = effortMinutes
        self.energyLevel = energyLevel
        self.calendarEventId = calendarEventId
        self.metadata = metadata
        self.deleted = deleted
        self.people = people
        self.deadline = deadline
        self.dueIsAllDay = dueIsAllDay
        self.pinned = pinned
        self.sortOrder = sortOrder
        self.gymSessionId = gymSessionId
        self.kind = kind.rawValue
    }

    /// A specific moment on the clock, as opposed to a whole-day intention.
    var hasSpecificTime: Bool {
        dueDate != nil && !dueIsAllDay
    }

    /// A fixed point the day is built around: a pinned time or a real calendar event. These
    /// never move when the timeline self-heals.
    var isAnchored: Bool {
        hasSpecificTime && (pinned || calendarEventId != nil)
    }

    /// Whether this row may be planned into a day at all.
    ///
    /// The single question every scheduling path asks, so the taxonomy's central promise —
    /// **an idea is never a chore** — is enforced in one place rather than re-derived in five.
    /// Before this existed the planner's fallback pool was "every open task", which is exactly
    /// how something you merely thought would end up occupying Tuesday afternoon.
    var isPlannable: Bool {
        status != "completed" && !deleted && captureKind.isSchedulable
    }

    /// A time the planner guessed, which may reflow as the day slips — the "liquid" part of
    /// the timeline.
    var isSoftScheduled: Bool {
        hasSpecificTime && !pinned && calendarEventId == nil
    }
}
