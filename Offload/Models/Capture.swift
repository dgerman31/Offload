import Foundation
import GRDB

/// A raw capture — the original voice/text input before extraction (spec §6 `captures`).
/// Persisted first, always, so nothing is lost if inference fails (spec §9 acceptance target).
struct Capture: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var rawInput: String
    var inputType: String?          // voice | text
    var transcript: String?
    var processingStatus: String    // pending | processing | done | failed
    var extractedTaskIds: String?   // JSON array
    var createdAt: String
    var processedAt: String?
    var processingMs: Int?
    var modelSource: String?        // foundation | mlx | cloud
    var metadata: String?

    static let databaseTableName = "captures"

    enum CodingKeys: String, CodingKey {
        case id
        case rawInput = "raw_input"
        case inputType = "input_type"
        case transcript
        case processingStatus = "processing_status"
        case extractedTaskIds = "extracted_task_ids"
        case createdAt = "created_at"
        case processedAt = "processed_at"
        case processingMs = "processing_ms"
        case modelSource = "model_source"
        case metadata
    }

    init(
        id: String = UUID().uuidString,
        rawInput: String,
        inputType: String? = nil,
        transcript: String? = nil,
        processingStatus: String = "pending",
        extractedTaskIds: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        processedAt: String? = nil,
        processingMs: Int? = nil,
        modelSource: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.rawInput = rawInput
        self.inputType = inputType
        self.transcript = transcript
        self.processingStatus = processingStatus
        self.extractedTaskIds = extractedTaskIds
        self.createdAt = createdAt
        self.processedAt = processedAt
        self.processingMs = processingMs
        self.modelSource = modelSource
        self.metadata = metadata
    }
}
