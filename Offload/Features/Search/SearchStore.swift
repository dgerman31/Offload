import Foundation
import GRDB

/// Search over tasks (spec §5.4). Full-text now; semantic/vector search is added with
/// embeddings later. Observes all tasks and filters in memory — fine at personal scale,
/// and keeps the matching logic pure and testable.
@MainActor
@Observable
final class SearchStore {
    var query = ""
    var category: String?
    var priority: String?

    private(set) var all: [TaskItem] = []

    var results: [TaskItem] {
        Self.filter(all, query: query, category: category, priority: priority)
    }

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

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
}
