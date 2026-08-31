import Foundation
import GRDB

/// A project clusters related tasks (spec §6 `projects`).
struct Project: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    var descriptionText: String?
    var status: String              // planning | on_track | stalled | completed
    var progressPercent: Int
    var createdAt: String
    var dueDate: String?
    var category: String?
    var metadata: String?
    var deleted: Bool
    /// Parent project, when this one is a subfolder. nil = top-level.
    var parentProjectId: String?

    /// Position on the hill, 0…1, or nil if this project isn't being tracked that way.
    ///
    /// The first half is *figuring it out* — you don't yet know what the answer looks like, and
    /// estimates here are fiction. The second half is *executing* — the unknowns are gone and it's
    /// just work. `progressPercent` can't express the difference, which is why a project can sit at
    /// "40% done" for a month while nothing actually moves.
    var hill: Double?
    /// When `hill` was last set. What makes a stalled project visible: it isn't the position that
    /// tells you something's stuck, it's the position not changing.
    var hillUpdatedAt: String?
    /// Manual position among its siblings. Nil = never dragged.
    var sortOrder: Double?
    /// Put away, not deleted. Finished projects shouldn't have to be destroyed to stop being noise.
    var archived: Bool

    static let databaseTableName = "projects"

    enum CodingKeys: String, CodingKey {
        case id, title
        case descriptionText = "description"
        case status
        case progressPercent = "progress_percent"
        case createdAt = "created_at"
        case dueDate = "due_date"
        case category, metadata, deleted
        case parentProjectId = "parent_project_id"
        case hill
        case hillUpdatedAt = "hill_updated_at"
        case sortOrder = "sort_order"
        case archived
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        descriptionText: String? = nil,
        status: String = "planning",
        progressPercent: Int = 0,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        dueDate: String? = nil,
        category: String? = nil,
        metadata: String? = nil,
        deleted: Bool = false,
        parentProjectId: String? = nil,
        hill: Double? = nil,
        hillUpdatedAt: String? = nil,
        sortOrder: Double? = nil,
        archived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.status = status
        self.progressPercent = progressPercent
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.category = category
        self.metadata = metadata
        self.deleted = deleted
        self.parentProjectId = parentProjectId
        self.hill = hill
        self.hillUpdatedAt = hillUpdatedAt
        self.sortOrder = sortOrder
        self.archived = archived
    }
}
