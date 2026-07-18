import Foundation
import GRDB

/// A user correction to a model-assigned field (spec §6 `corrections`). These feed
/// correction-driven adaptation later (learning the user's phrasing/categories).
struct Correction: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var taskId: String?
    var field: String
    var modelValue: String?
    var userValue: String?
    var createdAt: String

    static let databaseTableName = "corrections"

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case field
        case modelValue = "model_value"
        case userValue = "user_value"
        case createdAt = "created_at"
    }

    init(
        id: String = UUID().uuidString,
        taskId: String? = nil,
        field: String,
        modelValue: String? = nil,
        userValue: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.taskId = taskId
        self.field = field
        self.modelValue = modelValue
        self.userValue = userValue
        self.createdAt = createdAt
    }
}
