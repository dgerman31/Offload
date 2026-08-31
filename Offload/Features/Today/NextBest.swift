import Foundation

/// Picks the single "next best task" (spec §5.4). Deterministic heuristic for now — a
/// larger model can refine it later (energy/free-time aware). Highest priority first,
/// then least effort, then soonest due.
enum NextBest {
    static func pick(from tasks: [TaskItem]) -> TaskItem? {
        // `isPlannable` rather than merely "not completed": an idea, a note or a question is
        // never the answer to "what should I do next", and the callers' fallback pool is the whole
        // open list — which is where an unschedulable row would otherwise surface.
        let open = tasks.filter(\.isPlannable)
        guard !open.isEmpty else { return nil }

        func priorityRank(_ p: String) -> Int {
            switch p {
            case "high":   return 0
            case "medium": return 1
            default:       return 2
            }
        }

        return open.min { a, b in
            let (pa, pb) = (priorityRank(a.priority), priorityRank(b.priority))
            if pa != pb { return pa < pb }
            let (ea, eb) = (a.effortMinutes ?? .max, b.effortMinutes ?? .max)
            if ea != eb { return ea < eb }
            // ISO 8601 strings sort chronologically; nil (no due date) sorts last.
            return (a.dueDate ?? "~") < (b.dueDate ?? "~")
        }
    }
}
