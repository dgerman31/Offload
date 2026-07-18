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

    static let databaseTableName = "projects"

    enum CodingKeys: String, CodingKey {
        case id, title
        case descriptionText = "description"
        case status
        case progressPercent = "progress_percent"
        case createdAt = "created_at"
        case dueDate = "due_date"
        case category, metadata, deleted
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
        deleted: Bool = false
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
    }
}
