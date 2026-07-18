import Foundation
import GRDB

/// A detected pattern / suggestion from a background pass (spec §6 `patterns`, §3.6).
/// These are always surfaced as dismissible suggestions — never silently applied.
struct Pattern: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var patternType: String         // recurrence | breakdown | project_synthesis | insight
    var title: String?
    var relatedTaskIds: String?     // JSON array
    var confidence: Double?
    var suggestedAction: String?
    var userAccepted: Bool
    var createdAt: String
    var dismissedAt: String?

    static let databaseTableName = "patterns"

    enum CodingKeys: String, CodingKey {
        case id
        case patternType = "pattern_type"
        case title
        case relatedTaskIds = "related_task_ids"
        case confidence
        case suggestedAction = "suggested_action"
        case userAccepted = "user_accepted"
        case createdAt = "created_at"
        case dismissedAt = "dismissed_at"
    }

    init(
        id: String = UUID().uuidString,
        patternType: String,
        title: String? = nil,
        relatedTaskIds: String? = nil,
        confidence: Double? = nil,
        suggestedAction: String? = nil,
        userAccepted: Bool = false,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        dismissedAt: String? = nil
    ) {
        self.id = id
        self.patternType = patternType
        self.title = title
        self.relatedTaskIds = relatedTaskIds
        self.confidence = confidence
        self.suggestedAction = suggestedAction
        self.userAccepted = userAccepted
        self.createdAt = createdAt
        self.dismissedAt = dismissedAt
    }
}
