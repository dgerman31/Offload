import Foundation
import GRDB

/// Search over tasks (spec §5.4 / feature 14): token full-text PLUS on-device semantic
/// ranking — "kitchen stuff" finds "buy dish soap" even without shared words. Task title
/// vectors are cached as tasks stream in; the query is embedded per search.
@MainActor
@Observable
final class SearchStore {
    var query = ""
    var category: String?
    var priority: String?

    private(set) var all: [TaskItem] = []
    private var vectorCache: [String: [Double]] = [:]

    private let db: AppDatabase
    private let embedder: any TextEmbedding

    init(db: AppDatabase = .shared, embedder: any TextEmbedding = EmbeddingService()) {
        self.db = db
        self.embedder = embedder
    }

    var results: [TaskItem] {
        let token = Self.filter(all, query: query, category: category, priority: priority)

        // Semantic layer: only for real queries; appends meaning-matches below token matches.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let queryVector = embedder.vector(for: trimmed) else { return token }

        let tokenIds = Set(token.map(\.id))
        let candidates = all.compactMap { task in
            vectorCache[task.id].map { (id: task.id, vector: $0) }
        }
        let rankedIds = Self.semanticRank(queryVector: queryVector, candidates: candidates)
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let extras = rankedIds
            .filter { !tokenIds.contains($0) }
            .compactMap { byId[$0] }
            .filter { task in
                (category == nil || task.category == category) &&
                (priority == nil || task.priority == priority)
            }
        return token + extras
    }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try TaskItem
                .filter(Column("deleted") == false)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
        do {
            for try await tasks in observation.values(in: db.dbQueue) {
                all = tasks
                // Fill the vector cache lazily — only newly-seen tasks get embedded.
                for task in tasks where vectorCache[task.id] == nil {
                    if let v = embedder.vector(for: task.title) {
                        vectorCache[task.id] = v
                    }
                }
            }
        } catch {
            // Observation ended.
        }
    }

    func toggleComplete(_ item: TaskItem) async {
        var updated = item
        let nowCompleted = updated.status != "completed"
        updated.status = nowCompleted ? "completed" : "open"
        updated.completedAt = nowCompleted ? ISO8601DateFormatter().string(from: Date()) : nil
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    /// Pure filter: all query tokens must appear in title/description (AND), then apply
    /// the optional category/priority filters. Empty query matches everything.
    nonisolated static func filter(_ tasks: [TaskItem], query: String, category: String?, priority: String?) -> [TaskItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = q.split(separator: " ").map(String.init)

        return tasks.filter { task in
            if let category, task.category != category { return false }
            if let priority, task.priority != priority { return false }
            guard !tokens.isEmpty else { return true }
            let haystack = (task.title + " " + (task.descriptionText ?? "")).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// Pure semantic ranking: ids of candidates whose cosine similarity to the query
    /// clears the threshold, most-similar first.
    nonisolated static func semanticRank(
        queryVector: [Double],
        candidates: [(id: String, vector: [Double])],
        threshold: Double = 0.6
    ) -> [String] {
        candidates
            .map { (id: $0.id, score: VectorMath.cosineSimilarity(queryVector, $0.vector)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .map(\.id)
    }
}
