import Foundation
import GRDB

/// Observes projects with live progress derived from their tasks (spec §5.4).
@MainActor
@Observable
final class ProjectStore {

    /// A project plus its task rollup. Sendable so it can cross the observation boundary.
    struct Summary: Identifiable, Sendable, Equatable {
        let project: Project
        let total: Int
        let completed: Int
        var id: String { project.id }
        var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    }

    private(set) var summaries: [Summary] = []

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try ProjectStore.fetchSummaries(db)
        }
        do {
            for try await rows in observation.values(in: db.dbQueue) {
                summaries = rows
            }
        } catch {
            // Observation ended.
        }
    }

    /// Pure query (testable): every non-deleted project with its task counts.
    /// `nonisolated` because it runs on the database queue, not the main actor.
    nonisolated static func fetchSummaries(_ db: Database) throws -> [Summary] {
        let projects = try Project
            .filter(Column("deleted") == false)
            .order(Column("created_at").desc)
            .fetchAll(db)

        return try projects.map { project in
            let base = TaskItem
                .filter(Column("project_id") == project.id)
                .filter(Column("deleted") == false)
            let total = try base.fetchCount(db)
            let completed = try base.filter(Column("status") == "completed").fetchCount(db)
            return Summary(project: project, total: total, completed: completed)
        }
    }
}
