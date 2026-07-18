import Foundation

/// "I have N minutes" → a doable batch of tasks that fits (spec §4, feature 10).
/// Greedy: highest priority first, then least effort; add while the time budget allows.
/// Deterministic; a larger model can later factor in energy level and learned effort.
enum EnergyBatch {
    /// Assumed effort when a task doesn't have an estimate.
    static let defaultEffort = 15

    static func plan(tasks: [TaskItem], minutes: Int) -> [TaskItem] {
        let open = tasks.filter { $0.status != "completed" }

        func rank(_ p: String) -> Int {
            switch p {
            case "high":   return 0
            case "medium": return 1
            default:       return 2
            }
        }

        let sorted = open.sorted { a, b in
            let (ra, rb) = (rank(a.priority), rank(b.priority))
            if ra != rb { return ra < rb }
            return (a.effortMinutes ?? defaultEffort) < (b.effortMinutes ?? defaultEffort)
        }

        var remaining = minutes
        var batch: [TaskItem] = []
        for task in sorted {
            let cost = task.effortMinutes ?? defaultEffort
            if cost <= remaining {
                batch.append(task)
                remaining -= cost
            }
        }
        return batch
    }
}
