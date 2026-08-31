import Foundation
import GRDB

/// Observes one project: its direct subfolders (with their own rollups) and its tasks split
/// into To-do / Done (spec §5.4 project detail).
/// Everything one project's workspace shows, in a single `Sendable` snapshot — a named struct
/// rather than a tuple, because a `ValueObservation` value crosses out of the database's context
/// to reach the main actor, and a four-element tuple at that boundary is unreadable.
struct ProjectSnapshot: Sendable {
    var project: Project?
    var tasks: [TaskItem] = []
    var subfolders: [ProjectStore.Summary] = []
    var updates: [ProjectUpdate] = []
}

@MainActor
@Observable
final class ProjectDetailStore {
    /// The live project row. The view is handed one at init, but the hill, the target date and the
    /// archive flag all change *from* this screen — reading them back from the observation is what
    /// makes the header update as you drag rather than after you leave and come back.
    private(set) var project: Project?
    /// Everything filed under the project, in one list. Sectioning is `ProjectBoard`'s job, not a
    /// store's — it's a pure arrangement of rows and belongs somewhere testable.
    private(set) var tasks: [TaskItem] = []
    private(set) var todo: [TaskItem] = []
    private(set) var done: [TaskItem] = []
    private(set) var subfolders: [ProjectStore.Summary] = []
    /// The log, newest first.
    private(set) var updates: [ProjectUpdate] = []

    private let projectId: String
    private let db: AppDatabase
    private var started = false

    init(projectId: String, db: AppDatabase = .shared) {
        self.projectId = projectId
        self.db = db
    }

    /// Past hill positions, oldest first — what the chart draws behind the live dot.
    var hillHistory: [Double] {
        updates.reversed().compactMap(\.hill)
    }

    var isStalled: Bool {
        ProjectHill.isStalled(hill: project?.hill, hillUpdatedAt: project?.hillUpdatedAt)
    }

    func observe() async {
        guard !started else { return }
        started = true
        let pid = projectId   // capture a Sendable value, not self
        let observation = ValueObservation.tracking { db -> ProjectSnapshot in
            let tasks = try TaskItem
                .filter(Column("deleted") == false)
                .filter(Column("project_id") == pid)
                .order(Column("created_at"))
                .fetchAll(db)
            // Reuse the shared tree builder, then take just this project's direct children.
            let tree = try ProjectStore.fetchTree(db)
            let children = ProjectDetailStore.findChildren(of: pid, in: tree.roots)
            let project = try Project.fetchOne(db, key: pid)
            let updates = try ProjectUpdate
                .filter(Column("project_id") == pid)
                .order(Column("created_at").desc)
                .limit(30)
                .fetchAll(db)
            return ProjectSnapshot(project: project, tasks: tasks, subfolders: children, updates: updates)
        }
        do {
            for try await snapshot in observation.values(in: db.dbQueue) {
                project = snapshot.project
                tasks = snapshot.tasks
                // Manual order wins when set (drag-to-reorder); un-reordered tasks keep capture
                // order. Sorting in Swift keeps this independent of any GRDB ordering nuance.
                todo = ProjectDetailStore.byManualOrder(snapshot.tasks.filter { $0.status != "completed" })
                done = snapshot.tasks.filter { $0.status == "completed" }
                subfolders = snapshot.subfolders
                updates = snapshot.updates
            }
        } catch {
            Log.database.error("Project observation stopped: \(CaptureService.errorKind(error), privacy: .public)")
        }
        // Released when the stream ends, so re-entering the screen re-observes rather than sitting
        // frozen on the last snapshot. The same latch bug `SharedTasks` and the habits card had.
        started = false
    }

    // MARK: The hill

    /// Move the dot, and log where it landed.
    ///
    /// Every move writes a `ProjectUpdate`, because the history is the entire point: one position
    /// tells you where a project is, a series tells you whether it's moving, and only the second
    /// one can show you that something is stuck.
    func setHill(_ value: Double, note: String? = nil, now: Date = Date()) async {
        guard var project else { return }
        let clamped = ProjectHill.clamp(value)
        project.hill = clamped
        project.hillUpdatedAt = ISO8601DateFormatter().string(from: now)
        // A hill past the crest and no open work left is a project that's finished, and saying so
        // is better than leaving it in "planning" forever.
        if clamped >= 0.999 { project.status = "completed" }
        else if project.status == "completed" { project.status = "on_track" }
        let toSave = project
        let entry = ProjectUpdate(projectId: projectId,
                                  createdAt: ISO8601DateFormatter().string(from: now),
                                  hill: clamped,
                                  note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        try? await db.dbQueue.write { database in
            try toSave.update(database)
            try entry.insert(database)
        }
    }

    /// A dated line in the log with no hill change — "what happened" without having to re-answer
    /// "where is it".
    func logUpdate(note: String, now: Date = Date()) async {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let entry = ProjectUpdate(projectId: projectId,
                                  createdAt: ISO8601DateFormatter().string(from: now),
                                  hill: project?.hill,
                                  note: text)
        try? await db.dbQueue.write { try entry.insert($0) }
        Haptics.success()
    }

    func deleteUpdate(_ update: ProjectUpdate) async {
        try? await db.dbQueue.write { database in
            _ = try ProjectUpdate.deleteOne(database, key: update.id)
        }
    }

    // MARK: Project itself

    func setTargetDate(_ date: Date?) async {
        guard var project else { return }
        project.dueDate = date.map { DueDate.canonicalString(from: $0) }
        let toSave = project
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    func setArchived(_ archived: Bool) async {
        guard var project else { return }
        project.archived = archived
        let toSave = project
        try? await db.dbQueue.write { try toSave.update($0) }
        Haptics.success()
    }

    func setBrief(_ text: String) async {
        guard var project else { return }
        project.descriptionText = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let toSave = project
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    // MARK: Adding

    /// Add a row of a specific kind, straight into its section.
    ///
    /// This is what makes the taxonomy usable rather than merely correct: jotting an idea into a
    /// project has to be as cheap as adding a to-do, or every idea will be typed as a to-do because
    /// that was the box that was open.
    func add(_ title: String, kind: CaptureKind) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // New rows sort after anything already ordered by hand.
        let next = (tasks.compactMap(\.sortOrder).max() ?? 0) + 1
        let task = TaskItem(title: trimmed, projectId: projectId, sortOrder: next, kind: kind)
        try? await db.dbQueue.write { try task.insert($0) }
        Haptics.light()
    }

    /// Reorder a list the way SwiftUI's `.onMove` intends, without depending on SwiftUI in a
    /// store: `destination` is an offset in the pre-removal list. Pure, so it's unit-testable.
    nonisolated static func moved(_ items: [TaskItem], fromOffsets source: IndexSet, toOffset destination: Int) -> [TaskItem] {
        var result = items
        let moving = source.sorted().map { result[$0] }
        for index in source.sorted(by: >) { result.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: min(max(insertAt, 0), result.count))
        return result
    }

    /// Manual sort_order first (lower = higher), then capture order for anything never dragged.
    nonisolated static func byManualOrder(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            let lo = lhs.sortOrder ?? .greatestFiniteMagnitude
            let ro = rhs.sortOrder ?? .greatestFiniteMagnitude
            if lo != ro { return lo < ro }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Drag-to-reorder: apply the move locally for an instant response, then persist a compact
    /// 0..<n ordering for the whole to-do list so it survives relaunch and future captures slot
    /// below it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        let reordered = ProjectDetailStore.moved(todo, fromOffsets: source, toOffset: destination)
        todo = reordered
        let updates = reordered.enumerated().map { index, task -> TaskItem in
            var t = task
            t.sortOrder = Double(index)
            return t
        }
        try? await db.dbQueue.write { database in
            for task in updates { try task.update(database) }
        }
        Haptics.light()
    }

    /// Depth-first search for a project's node in the tree, returning its direct children.
    nonisolated static func findChildren(of id: String, in summaries: [ProjectStore.Summary]) -> [ProjectStore.Summary] {
        for summary in summaries {
            if summary.id == id { return summary.children }
            let nested = findChildren(of: id, in: summary.children)
            if !nested.isEmpty { return nested }
        }
        return []
    }

    func addSubfolder(named title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let child = Project(title: trimmed, parentProjectId: projectId)
        try? await db.dbQueue.write { try child.insert($0) }
        Haptics.success()
    }

    /// Apply a section's new order.
    ///
    /// Scoped to the rows that were actually on screen: a project's Next actions are reordered
    /// without touching the ideas or the notes, which have their own order and no drag handles.
    /// The written `sortOrder`s are spaced within the range those rows already occupied, so a
    /// reorder inside one section can't reshuffle another.
    func reorder(_ orderedIDs: [String], within section: [TaskItem]) async {
        let byId = Dictionary(section.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = orderedIDs.compactMap { byId[$0] }
        guard reordered.count == section.count else { return }
        // Reuse the positions this section already held, so the numbers stay dense and every other
        // section's ordering is left exactly as it was.
        let slots = section.enumerated().map { index, task in task.sortOrder ?? Double(index) }.sorted()
        let updates = zip(reordered, slots).map { task, slot -> TaskItem in
            var t = task
            t.sortOrder = slot
            return t
        }
        try? await db.dbQueue.write { database in
            for task in updates { try task.update(database) }
        }
        Haptics.light()
    }

    func toggleComplete(_ item: TaskItem) async {
        await TaskActions.toggleComplete(item, db: db)
    }
}
