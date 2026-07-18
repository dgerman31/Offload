import Foundation

/// Abstraction over the extractor so the capture pipeline can be unit-tested with a
/// fake (the real on-device model can't run on a headless CI runner).
@MainActor
protocol TaskExtracting {
    func extract(from transcript: String) async throws -> ExtractedCapture
}

/// The end-to-end capture pipeline (spec §2.3). Persists the raw input FIRST so nothing
/// is ever lost on inference failure (spec §9 acceptance target), then extracts, maps,
/// and persists the resulting project + tasks, recording latency and model source.
@MainActor
final class CaptureService {

    struct Outcome: Equatable {
        var addedTasks: Int
        var projectTitle: String?
    }

    private let db: AppDatabase
    private let extractor: any TaskExtracting

    init(db: AppDatabase = .shared, extractor: any TaskExtracting = ExtractionService()) {
        self.db = db
        self.extractor = extractor
    }

    func process(rawInput: String, inputType: String) async throws -> Outcome {
        let started = Date()

        // 1. Persist the raw capture first — never lose the user's words.
        var capture = Capture(
            rawInput: rawInput,
            inputType: inputType,
            transcript: rawInput,
            processingStatus: "processing"
        )
        try db.dbQueue.write { try capture.insert($0) }

        do {
            // 2. Extract (typed output; no parsing).
            let extracted = try await extractor.extract(from: rawInput)
            let mapped = CaptureMapper.map(extracted)

            // 3. Persist project + tasks in one transaction.
            try db.dbQueue.write { database in
                if let project = mapped.project { try project.insert(database) }
                for task in mapped.tasks { try task.insert(database) }
            }

            // 4. Finalize the capture with instrumentation (spec §9).
            capture.processingStatus = "done"
            capture.processedAt = ISO8601DateFormatter().string(from: Date())
            capture.processingMs = Int(Date().timeIntervalSince(started) * 1000)
            capture.modelSource = "foundation"
            capture.extractedTaskIds = Self.encodeIds(mapped.tasks.map(\.id))
            try db.dbQueue.write { try capture.update($0) }

            return Outcome(addedTasks: mapped.tasks.count, projectTitle: mapped.project?.title)
        } catch {
            // Keep the raw transcript; mark failed so it can be retried later.
            capture.processingStatus = "failed"
            try? db.dbQueue.write { try capture.update($0) }
            throw error
        }
    }

    private static func encodeIds(_ ids: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
