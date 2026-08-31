import Foundation
import GRDB

/// Everything the model should know about this person's world before it reads a sentence of theirs.
///
/// ### Why this is worth the tokens
///
/// A capture is a fragment. "Ask him about the dataset before Thursday" is unresolvable in
/// isolation and trivial with context: *him* is the PI named in the brief, *the dataset* belongs to
/// the chart-review project, and Thursday is the committee meeting already on the calendar. The
/// model's ceiling isn't its reasoning, it's what it's allowed to know — and until this existed it
/// was allowed to know a dictionary of corrections and nothing else.
///
/// The single highest-value block here is the **project list**. Without it the model invents
/// "Thesis" alongside the "Thesis project" that already exists, and the two never merge; with it,
/// filing is a lookup rather than a guess.
///
/// ### Ordering
///
/// The blocks are assembled in the order a person would need them: who this is, what they're
/// running, what they've been doing lately, what's stuck, what words they use, and finally where
/// the model has previously been wrong. Context first, overrides last — the corrections have to be
/// the most recent thing read, because they win.
enum CaptureContext {

    /// How much history is worth including. Generous on purpose: the budget here is tokens, and the
    /// cost of a missing project is a duplicate that has to be merged by hand forever.
    static let recentDays = 14
    static let maxRecentTitles = 40
    static let maxProjects = 30
    static let maxCorrections = 20
    static let maxOpenLoops = 12

    /// The whole briefing, or nil when there's genuinely nothing to say (a brand-new install), so a
    /// first capture's prompt stays exactly as clean as it was before any of this existed.
    static func assemble(
        db: AppDatabase,
        matching transcript: String? = nil,
        profile: LearnedProfile = .stored(),
        brief: LifeBrief = .stored(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> String? {
        let world = await world(db: db, now: now, calendar: calendar)
        let corrections = await Personalization.fragment(db: db, profile: profile,
                                                         matching: transcript,
                                                         limit: maxCorrections)
        let blocks: [String?] = [
            brief.promptFragment(),
            projectsBlock(world.projects),
            recentBlock(world.recentTitles),
            openLoopsBlock(waiting: world.waiting, questions: world.questions),
            corrections
        ]
        let parts = blocks.compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Reading the world

    /// One project, as the model needs to see it: what it's called, what it is, and how live it is.
    struct ProjectLine: Sendable, Equatable {
        var title: String
        var brief: String?
        var openCount: Int
        var ideaCount: Int
        var targetDate: String?
    }

    struct World: Sendable {
        var projects: [ProjectLine] = []
        var recentTitles: [String] = []
        var waiting: [String] = []
        var questions: [String] = []
    }

    static func world(db: AppDatabase, now: Date = Date(), calendar: Calendar = .current) async -> World {
        let cutoff = calendar.date(byAdding: .day, value: -recentDays, to: now) ?? now
        let data = try? await db.dbQueue.read { database -> (projects: [Project], tasks: [TaskItem]) in
            let projects = try Project
                .filter(Column("deleted") == false && Column("archived") == false)
                .order(Column("created_at").desc)
                .limit(maxProjects)
                .fetchAll(database)
            let tasks = try TaskItem
                .filter(Column("deleted") == false)
                .fetchAll(database)
            return (projects, tasks)
        }
        guard let data else { return World() }
        return assembleWorld(projects: data.projects, tasks: data.tasks, since: cutoff)
    }

    /// The pure half, so what the model gets to see is unit-tested rather than inspected in a log.
    static func assembleWorld(projects: [Project], tasks: [TaskItem], since cutoff: Date) -> World {
        let living = tasks.filter { !$0.deleted }
        let byProject = Dictionary(grouping: living.filter { $0.projectId != nil },
                                   by: { $0.projectId ?? "" })

        var world = World()
        world.projects = projects.map { project in
            let items = byProject[project.id] ?? []
            return ProjectLine(
                title: project.title,
                brief: project.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                openCount: items.filter { $0.status != "completed" && $0.captureKind.isSchedulable }.count,
                ideaCount: items.filter { $0.captureKind == .idea }.count,
                targetDate: project.dueDate
            )
        }

        // Recently touched work, so a fragment like "the paper" or "that email" has something to
        // resolve against. Completed *and* created, because both say what's currently on their mind.
        let recent = living.filter { task in
            if let done = DueDate.parse(task.completedAt), done >= cutoff { return true }
            if let made = DueDate.parse(task.createdAt), made >= cutoff { return true }
            return false
        }
        world.recentTitles = Array(
            recent
                .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
                .map(\.title)
                .reduced(to: maxRecentTitles)
        )

        world.waiting = Array(living
            .filter { $0.status != "completed" && ($0.captureKind == .waiting || $0.status == "waiting") }
            .map(\.title)
            .prefix(maxOpenLoops))
        world.questions = Array(living
            .filter { $0.status != "completed" && $0.captureKind == .question }
            .map(\.title)
            .prefix(maxOpenLoops))
        return world
    }

    // MARK: Rendering

    /// The block that stops duplicate projects existing.
    static func projectsBlock(_ projects: [ProjectLine]) -> String? {
        guard !projects.isEmpty else { return nil }
        let lines = projects.map { project -> String in
            var parts: [String] = []
            if project.openCount > 0 { parts.append("\(project.openCount) open") }
            if project.ideaCount > 0 { parts.append("\(project.ideaCount) idea\(project.ideaCount == 1 ? "" : "s")") }
            if let target = DueDate.parse(project.targetDate) {
                parts.append("target \(target.formatted(.dateTime.day().month(.abbreviated)))")
            }
            let stats = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
            let brief = project.brief.map { " — \($0)" } ?? ""
            return "- \"\(project.title)\"\(stats)\(brief)"
        }
        return """
        THEIR PROJECTS, exactly as titled. When something they say belongs to one of these, put that \
        title **verbatim** in `suggestedProject`. Match an existing project rather than inventing a \
        near-duplicate — "Thesis" and "My thesis" must never both exist, and a project the app \
        creates by accident has to be merged by hand forever. Invent a new name only when nothing \
        here fits:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Lets a fragment resolve against what they've actually been doing.
    static func recentBlock(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        return """
        WHAT THEY'VE BEEN DOING in the last two weeks. Use it to resolve vague references — "the \
        paper", "that email", "him" — and to judge what's routine for them versus unusual. Do not \
        treat any of it as something to recreate:
        \(titles.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    /// What's already outstanding, so the model can recognise an answer to it rather than filing a
    /// near-duplicate beside it.
    static func openLoopsBlock(waiting: [String], questions: [String]) -> String? {
        guard !waiting.isEmpty || !questions.isEmpty else { return nil }
        var sections: [String] = []
        if !waiting.isEmpty {
            sections.append("Already waiting on someone for:\n" + waiting.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !questions.isEmpty {
            sections.append("Open questions they haven't answered yet:\n" + questions.map { "- \($0)" }.joined(separator: "\n"))
        }
        return """
        WHAT'S ALREADY OUTSTANDING. If what they've just said resolves one of these — the reply \
        arrived, the question got answered — say so in `reasoning` rather than filing a second copy \
        of it:
        \(sections.joined(separator: "\n\n"))
        """
    }
}

private extension Array where Element == String {
    /// The first `limit` distinct entries, case-insensitively — a recurring task shouldn't spend
    /// eight of the forty slots saying the same thing.
    func reduced(to limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in self {
            let key = item.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }
}
