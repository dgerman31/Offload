import Foundation
import GRDB

/// Abstraction over the extractor so the capture pipeline can be unit-tested with a
/// fake (the real on-device model can't run on a headless CI runner).
@MainActor
protocol TaskExtracting {
    func extract(from transcript: String) async throws -> ExtractedCapture
}

/// The end-to-end capture pipeline (spec §2.3). Persists the raw input FIRST so nothing
/// is ever lost on inference failure (spec §9 acceptance target), then extracts, maps,
/// and persists the resulting project + tasks, recording latency and model source.
///
/// Note: in an async context GRDB's `write` is the async overload, whose closure is
/// `@Sendable` — so we hand each write an immutable copy rather than a captured `var`.
@MainActor
final class CaptureService {

    /// UserDefaults key for the dedupe-sensitivity slider in Settings (spec §3.5: tunable).
    nonisolated static let dedupeThresholdKey = "offload.dedupeThreshold"

    struct Outcome: Equatable {
        var addedTasks: Int
        var taskTitles: [String]
        var projectTitle: String?
        var similarWarnings: [String] = []
    }

    private let db: AppDatabase
    private let extractor: any TaskExtracting
    private let embedder: any TextEmbedding

    init(
        db: AppDatabase = .shared,
        extractor: any TaskExtracting = ExtractionService(),
        embedder: any TextEmbedding = EmbeddingService()
    ) {
        self.db = db
        self.extractor = extractor
        self.embedder = embedder
    }

    func process(rawInput: String, inputType: String) async throws -> Outcome {
        let started = Date()

        // 1. Persist the raw capture first — never lose the user's words.
        let initial = Capture(
            rawInput: rawInput,
            inputType: inputType,
            transcript: rawInput,
            processingStatus: "processing"
        )
        try await db.dbQueue.write { try initial.insert($0) }

        do {
            // 2. Extract (typed output; no parsing).
            let extracted = try await extractor.extract(from: rawInput)
            let mapped = CaptureMapper.map(extracted)

            // 2b. Dedup check (spec §3.5): compare new titles against existing open tasks
            // by embedding similarity. Keep both (never silently merge) but surface it.
            let existing = try await db.dbQueue.read { database in
                try TaskItem
                    .filter(Column("deleted") == false)
                    .filter(Column("status") != "completed")
                    .fetchAll(database)
            }
            let stored = UserDefaults.standard.double(forKey: Self.dedupeThresholdKey)
            let warnings = Self.similarWarnings(
                newTitles: mapped.tasks.map(\.title),
                existingTitles: existing.map(\.title),
                embedder: embedder,
                threshold: stored > 0 ? stored : 0.85
            )

            // 3. Persist project + tasks in one transaction.
            try await db.dbQueue.write { database in
                if let project = mapped.project { try project.insert(database) }
                for task in mapped.tasks { try task.insert(database) }
            }

            // 4. Finalize the capture with instrumentation (spec §9).
            var done = initial
            done.processingStatus = "done"
            done.processedAt = ISO8601DateFormatter().string(from: Date())
            done.processingMs = Int(Date().timeIntervalSince(started) * 1000)
            done.modelSource = "foundation"
            done.extractedTaskIds = Self.encodeIds(mapped.tasks.map(\.id))
            let finalized = done
            try await db.dbQueue.write { try finalized.update($0) }

            return Outcome(
                addedTasks: mapped.tasks.count,
                taskTitles: mapped.tasks.map(\.title),
                projectTitle: mapped.project?.title,
                similarWarnings: warnings
            )
        } catch {
            // Keep the raw transcript; mark failed so it can be retried later.
            var failed = initial
            failed.processingStatus = "failed"
            let finalized = failed
            try? await db.dbQueue.write { try finalized.update($0) }
            throw error
        }
    }

    private static func encodeIds(_ ids: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pure (embedder-injected) similarity pass: one warning per new title whose best
    /// match among existing titles clears the threshold. Testable with a fake embedder.
    nonisolated static func similarWarnings(
        newTitles: [String],
        existingTitles: [String],
        embedder: any TextEmbedding,
        threshold: Double = 0.85
    ) -> [String] {
        guard !existingTitles.isEmpty else { return [] }
        let existingVectors: [(title: String, vector: [Double])] = existingTitles.compactMap { title in
            embedder.vector(for: title).map { (title, $0) }
        }
        guard !existingVectors.isEmpty else { return [] }

        var warnings: [String] = []
        for title in newTitles {
            guard let v = embedder.vector(for: title) else { continue }
            if let best = existingVectors
                .map({ (title: $0.title, score: VectorMath.cosineSimilarity(v, $0.vector)) })
                .max(by: { $0.score < $1.score }),
               best.score >= threshold {
                warnings.append("“\(title)” looks similar to existing “\(best.title)”")
            }
        }
        return warnings
    }
}
