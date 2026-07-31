import Foundation

/// Whether something you just said is already on your list.
///
/// The premise of the app is that you say a thing the moment it occurs to you and stop carrying
/// it. The direct consequence is that you say the same thing twice — on Tuesday because you
/// remembered it, and on Thursday because you'd forgotten you'd remembered it. Without this,
/// that's two tasks, and the list slowly fills with the same worry restated.
///
/// Reuses `ProjectMatcher`'s normalization and distance rules rather than reimplementing them,
/// including the one that matters most: **numbers must agree**. "Review lecture 4" and "review
/// lecture 5" are the closest possible neighbours by every text measure and the least mergeable
/// pair in the list.
///
/// ### Deliberately more conservative than the project matcher
///
/// A wrongly-merged project is an annoyance you can see and fix. A wrongly-dropped task is work
/// that silently never happens, which is the exact failure this app exists to prevent. So there's
/// no meaning-based tier here — no embeddings, no "these are probably the same idea". Only
/// near-identical text counts, and anything with a stated time is always kept, because "call the
/// clinic at 3" said on two different days is two different calls.
enum TaskMatcher {

    struct Match: Sendable, Equatable {
        let task: TaskItem
        let confidence: ProjectMatcher.Confidence
    }

    /// An existing open task that says the same thing, or `nil` when this is genuinely new.
    static func duplicate(of title: String, among tasks: [TaskItem]) -> Match? {
        let target = ProjectMatcher.normalize(title)
        guard !target.isEmpty else { return nil }

        // Only work that's still outstanding. A finished task is history — saying it again
        // means you want to do it again, which is a new task and not a duplicate of an old one.
        let live = tasks.filter { $0.status != "completed" && !$0.deleted && $0.parentTaskId == nil }
        guard !live.isEmpty else { return nil }

        if let exact = live.first(where: { ProjectMatcher.normalize($0.title) == target }) {
            return Match(task: exact, confidence: .exact)
        }
        for task in live {
            let candidate = ProjectMatcher.normalize(task.title)
            guard !candidate.isEmpty, ProjectMatcher.numbersAgree(target, candidate) else { continue }
            let tolerance = ProjectMatcher.editTolerance(for: min(target.count, candidate.count))
            if ProjectMatcher.levenshtein(target, candidate) <= tolerance {
                return Match(task: task, confidence: .close)
            }
        }
        return nil
    }

    /// Split freshly-extracted tasks into the ones to create and the ones already covered.
    ///
    /// A task carrying a real clock time is never treated as a duplicate: a stated time is a
    /// commitment, and two commitments that happen to share a name are still two commitments.
    /// Steps are never matched either — they're scoped to their parent, and two parents can
    /// legitimately both have a step called "email the PI".
    static func partition(
        newTasks: [TaskItem],
        existing: [TaskItem]
    ) -> (create: [TaskItem], duplicates: [(task: TaskItem, existing: TaskItem)]) {
        var create: [TaskItem] = []
        var duplicates: [(task: TaskItem, existing: TaskItem)] = []
        // Grows as we go, so two identical tasks *within one capture* also collapse — saying the
        // same thing twice in one breath is if anything more likely than saying it twice in a week.
        var pool = existing

        for task in newTasks {
            guard task.parentTaskId == nil, !task.hasSpecificTime,
                  let match = duplicate(of: task.title, among: pool) else {
                create.append(task)
                pool.append(task)
                continue
            }
            duplicates.append((task, match.task))
        }

        // A step whose parent turned out to be a duplicate has nowhere to live: its parent id
        // points at a task that was never created. Re-point those at the existing task instead,
        // so a re-capture that adds detail lands as new steps on the thing you already had.
        let droppedIds = Set(duplicates.map(\.task.id))
        let survivorFor = Dictionary(duplicates.map { ($0.task.id, $0.existing.id) },
                                     uniquingKeysWith: { first, _ in first })
        create = create.map { task in
            guard let parent = task.parentTaskId, droppedIds.contains(parent) else { return task }
            var reparented = task
            reparented.parentTaskId = survivorFor[parent]
            return reparented
        }
        return (create, duplicates)
    }
}
