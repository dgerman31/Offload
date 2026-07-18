import Foundation
import GRDB

/// Runs pattern detection over the database and manages the resulting suggestions
/// (spec §3.6). Suggestions are dismissible rows in `patterns`; accepting a recurrence
/// applies the RRULE to the newest matching task — the user always pulls the trigger.
@MainActor
@Observable
final class PatternService {
    static let shared = PatternService()

    private(set) var suggestions: [Pattern] = []

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    /// Detect fresh patterns, persist new ones (deduped by title key), reload active list.
    func refresh() async {
        guard let tasks = try? await db.dbQueue.read({ database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) else { return }

        let existing = (try? await db.dbQueue.read { database in
            try Pattern.fetchAll(database)
        }) ?? []
        let existingTitles = Set(existing.map { $0.title ?? "" })

        var newRows: [Pattern] = []

        for suggestion in PatternDetector.recurrenceSuggestions(tasks: tasks) {
            let title = "“\(suggestion.displayTitle)” keeps coming up — make it \(suggestion.cadenceLabel)?"
            guard !existingTitles.contains(title) else { continue }
            newRows.append(Pattern(
                patternType: "recurrence",
                title: title,
                relatedTaskIds: Self.encode(suggestion.taskIds),
                confidence: min(1.0, Double(suggestion.taskIds.count) / 5.0),
                suggestedAction: suggestion.suggestedRule
            ))
        }

        for suggestion in PatternDetector.breakdownSuggestions(tasks: tasks, now: Date()) {
            let title = "“\(suggestion.title)” has slipped \(suggestion.overdueDays) days — break it into smaller steps?"
            guard !existingTitles.contains(title) else { continue }
            newRows.append(Pattern(
                patternType: "breakdown",
                title: title,
                relatedTaskIds: Self.encode([suggestion.taskId]),
                confidence: 0.7
            ))
        }

        if !newRows.isEmpty {
            let rows = newRows
            try? await db.dbQueue.write { database in
                for row in rows { try row.insert(database) }
            }
        }

        await reload()
    }

    func reload() async {
        suggestions = (try? await db.dbQueue.read { database in
            try Pattern
                .filter(Column("dismissed_at") == nil)
                .filter(Column("user_accepted") == false)
                .order(Column("created_at").desc)
                .fetchAll(database)
        }) ?? []
    }

    /// Accept a recurrence suggestion: apply the RRULE to the newest related open task.
    func accept(_ pattern: Pattern) async {
        if pattern.patternType == "recurrence",
           let rule = pattern.suggestedAction,
           let ids = Self.decode(pattern.relatedTaskIds) {
            try? await db.dbQueue.write { database in
                let newest = try TaskItem
                    .filter(ids.contains(Column("id")))
                    .order(Column("created_at").desc)
                    .fetchOne(database)
                if var task = newest {
                    task.recurrenceRule = rule
                    try task.update(database)
                }
            }
        }
        var accepted = pattern
        accepted.userAccepted = true
        let row = accepted
        try? await db.dbQueue.write { try row.update($0) }
        await reload()
    }

    func dismiss(_ pattern: Pattern) async {
        var dismissed = pattern
        dismissed.dismissedAt = ISO8601DateFormatter().string(from: Date())
        let row = dismissed
        try? await db.dbQueue.write { try row.update($0) }
        await reload()
    }

    private static func encode(_ ids: [String]) -> String? {
        (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func decode(_ json: String?) -> [String]? {
        json?.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }
}
