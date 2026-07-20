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
        case metadata, deleted, people
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
        people: String? = nil
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
    }
}
