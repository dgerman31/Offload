import Foundation
import GRDB

/// Abstraction over the extractor so the capture pipeline can be unit-tested with a
/// fake (the real on-device model can't run on a headless CI runner).
@MainActor
protocol TaskExtracting {
    func extract(from transcript: String) async throws -> ExtractionResult
}

/// How the user chose to resolve a near-duplicate before saving (spec §3.5).
/// - `keepBoth`: insert the new task as-is (the pre-blocking default behavior).
/// - `skip`: discard the new task entirely; the existing task is untouched.
/// - `merge`: discard the new task but opportunistically backfill the existing task's
///   empty `dueDate` / `recurrenceRule` (and raise its priority) from the new capture.
enum DuplicateResolution: Equatable, Sendable {
    case keepBoth
    case skip
    case merge
}

/// A near-duplicate the UI must resolve before insertion: a freshly-extracted task that
/// looks like an existing open task (spec §3.5). `id` is the new task's id, which doubles
/// as the resolution key handed back to `finalize`.
struct DuplicateCandidate: Identifiable, Equatable, Sendable {
    var newTaskId: String
    var newTitle: String
    var existingTaskId: String
    var existingTitle: String
    var score: Double

    var id: String { newTaskId }
}

/// Everything the capture pipeline computed up to (but not including) insertion: the raw
/// capture row, the mapped project/tasks, and any duplicate candidates awaiting a decision.
/// Produced by `CaptureService.prepare`, consumed by `CaptureService.finalize`. All fields
/// are value types, so it carries freely without isolation friction.
struct PreparedCapture {
    var initial: Capture
    var startedAt: Date
    var project: Project?
    var tasks: [TaskItem]
    var candidates: [DuplicateCandidate]
    /// Existing open tasks keyed by id — the merge/skip targets a resolution may act on.
    var existingById: [String: TaskItem]
    /// Ids of tasks the model flagged as time-anchored appointments — those that survive the
    /// duplicate resolution become real calendar events during `finalize` (spec §3.3 write).
    var appointmentTaskIds: Set<String> = []
    /// Fast, tappable refinements the model offered for this capture's ambiguities (Gemini
    /// only). Surfaced on the success screen; applied to the just-saved tasks with no round-trip.
    var chips: [ClarifyChip] = []
    /// Feature D: routines extracted from commitment-shaped tasks ("gym 5×/week", "class M–Th
    /// 9–12"). Persisted in `finalize` alongside normal tasks. The tasks they came from are
    /// removed from `tasks` so they don't also create one-off `TaskItem`s.
    var routines: [Routine] = []
}

/// The end-to-end capture pipeline (spec §2.3). Persists the raw input FIRST so nothing
/// is ever lost on inference failure (spec §9 acceptance target), then extracts, maps,
/// and persists the resulting project + tasks, recording latency and model source.
///
/// Insertion is split into two steps so near-duplicates can *block* on a Merge / Keep both /
/// Skip choice before anything is written (spec §3.5): `prepare` does everything through the
/// similarity check without inserting; `finalize` applies the per-candidate resolutions and
/// writes. `process` chains them with an auto-"keep both" resolution for callers that have no
/// UI to prompt with (Siri's `DictateCaptureIntent`, unit tests) — preserving prior behavior.
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
        /// Ids of the tasks actually inserted — the targets a tapped chip patches.
        var insertedTaskIds: [String] = []
        /// The clarifying chips to offer for this capture (empty on a confident capture).
        var chips: [ClarifyChip] = []
    }

    private let db: AppDatabase
    private let extractor: any TaskExtracting
    private let embedder: any TextEmbedding
    private let calendarWriter: any CalendarWriting

    init(
        db: AppDatabase = .shared,
        extractor: any TaskExtracting = SmartExtractionService(),
        embedder: any TextEmbedding = EmbeddingService(),
        calendarWriter: any CalendarWriting = EventKitCalendarWriter()
    ) {
        self.db = db
        self.extractor = extractor
        self.embedder = embedder
        self.calendarWriter = calendarWriter
    }

    // MARK: Prepare (everything up to, but not including, insertion)

    /// Persist the raw capture, extract, map, and compute duplicate candidates — but insert
    /// nothing yet. On extraction failure the raw capture is marked `failed` and the error
    /// is rethrown (the words are already saved). The returned `PreparedCapture` must be
    /// handed to `finalize` to actually write anything.
    func prepare(rawInput: String, inputType: String) async throws -> PreparedCapture {
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
            // 2. Extract (typed output; no parsing). Gemini also returns clarifying chips and its
            // own command-vs-to-do judgment; the on-device fallback returns neither.
            let extraction = try await extractor.extract(from: rawInput)
            let mapped = CaptureMapper.map(
                extraction.capture,
                sourceText: rawInput,
                isCommand: extraction.isProjectCommand
            )

            // 2b. Dedup check (spec §3.5): compare new tasks against existing open tasks by
            // embedding similarity. Rather than warn after the fact, surface candidates the
            // UI can block on before insertion.
            let existing = try await db.dbQueue.read { database in
                try TaskItem
                    .filter(Column("deleted") == false)
                    .filter(Column("status") != "completed")
                    .fetchAll(database)
            }
            let stored = UserDefaults.standard.double(forKey: Self.dedupeThresholdKey)
            let candidates = Self.duplicateCandidates(
                newTasks: mapped.tasks,
                existingTasks: existing,
                embedder: embedder,
                threshold: stored > 0 ? stored : 0.85
            )

            // Feature D: split commitment-shaped tasks (recurrence rules) into Routine models
            // so they block out the week rather than creating one-off tasks. The remaining
            // non-commitment tasks go through the normal pipeline.
            let commitment = CommitmentParser.parse(extraction.capture)
            let effectiveTasks = commitment.routines.isEmpty
                ? mapped.tasks
                : mapped.tasks.filter { task in
                    // Keep tasks whose titles weren't converted to routines.
                    !commitment.routines.contains { $0.title == task.title }
                }

            return PreparedCapture(
                initial: initial,
                startedAt: started,
                project: mapped.project,
                tasks: effectiveTasks,
                candidates: candidates,
                existingById: Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                appointmentTaskIds: mapped.appointmentTaskIds,
                chips: extraction.chips,
                routines: commitment.routines
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

    // MARK: Finalize (apply resolutions, then insert)

    /// Apply a resolution per duplicate candidate (keyed by candidate id; anything unlisted
    /// defaults to `.keepBoth`), then insert the surviving project + tasks and finalize the
    /// capture instrumentation (spec §9). Returns the same `Outcome` shape as before.
    func finalize(_ prepared: PreparedCapture, resolutions: [String: DuplicateResolution]) async throws -> Outcome {
        // Resolve each candidate: build the set of new tasks to drop, the existing tasks to
        // backfill via merge, and the "kept anyway" warnings to surface after save.
        var droppedNewTaskIds = Set<String>()
        var backfills: [String: TaskItem] = [:]     // existingTaskId -> updated existing task
        var warnings: [String] = []

        for candidate in prepared.candidates {
            switch resolutions[candidate.id] ?? .keepBoth {
            case .keepBoth:
                warnings.append(Self.warningText(newTitle: candidate.newTitle, existingTitle: candidate.existingTitle))
            case .skip:
                droppedNewTaskIds.insert(candidate.newTaskId)
            case .merge:
                droppedNewTaskIds.insert(candidate.newTaskId)
                // Chain merges so multiple new tasks can backfill the same existing task.
                let base = backfills[candidate.existingTaskId] ?? prepared.existingById[candidate.existingTaskId]
                if let existing = base,
                   let newTask = prepared.tasks.first(where: { $0.id == candidate.newTaskId }) {
                    backfills[candidate.existingTaskId] = Self.merge(newTask: newTask, into: existing)
                }
            }
        }

        // Dropping a parent must drop its children too, so no subtask is orphaned.
        let allDropped = Self.withDescendants(of: droppedNewTaskIds, in: prepared.tasks)
        let survivingTasks = prepared.tasks.filter { !allDropped.contains($0.id) }

        // 2c. Calendar write (spec §3.3): a surviving, time-anchored appointment becomes a real
        // EventKit event; we stamp its `calendarEventId` before insert so it's stored atomically.
        let finalTasks = await attachCalendarEvents(
            to: survivingTasks,
            appointmentTaskIds: prepared.appointmentTaskIds.subtracting(allDropped)
        )

        // 2d. Auto-fit (feature C): silently give loose, undated captures a soft slot in today's
        // open time so they land on the schedule instead of an undated pile. Stated-time and
        // project/subtasks are untouched. Best-effort — a fit failure never blocks the capture.
        let existingTasks = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        let fittedTasks = AutoFit.fitIntoToday(new: finalTasks, existing: existingTasks)

        // 3. Persist surviving project + tasks and any merge backfills in one transaction.
        let project = prepared.project
        // Insert the project when it still has tasks, OR when it was intentionally created
        // empty ("create a project called X" — a container command, which maps to no tasks).
        // The only case we skip is a project whose tasks all got dropped by dedup resolution.
        let insertProject = project != nil && (!finalTasks.isEmpty || prepared.tasks.isEmpty)
        let backfillUpdates = Array(backfills.values)
        // Feature D: routines from commitment-shaped captures.
        let newRoutines = prepared.routines
        try await db.dbQueue.write { database in
            if insertProject, let project { try project.insert(database) }
            for task in fittedTasks { try task.insert(database) }
            for updated in backfillUpdates { try updated.update(database) }
            for routine in newRoutines { try routine.insert(database) }
        }

        // 4. Finalize the capture with instrumentation (spec §9).
        var done = prepared.initial
        done.processingStatus = "done"
        done.processedAt = ISO8601DateFormatter().string(from: Date())
        done.processingMs = Int(Date().timeIntervalSince(prepared.startedAt) * 1000)
        done.modelSource = "foundation"
        done.extractedTaskIds = Self.encodeIds(finalTasks.map(\.id))
        let finalized = done
        try await db.dbQueue.write { try finalized.update($0) }

        // Chips only make sense when there's a task to refine. A capture that produced a
        // container-only command, or whose tasks were all deduped away, gets none.
        let chips = finalTasks.isEmpty ? [] : prepared.chips
        return Outcome(
            addedTasks: finalTasks.count,
            taskTitles: finalTasks.map(\.title),
            projectTitle: insertProject ? project?.title : nil,
            similarWarnings: warnings,
            insertedTaskIds: finalTasks.map(\.id),
            chips: chips
        )
    }

    // MARK: Chips — apply a tapped refinement to the just-saved tasks (no round-trip)

    /// Apply one clarifying chip's deterministic patch to the given tasks and persist it. Per-task
    /// patches (due date, priority, recurrence, category) come from `ClarifyChip.patch`; the one
    /// exception is `.assignProject`, which creates/reuses a container and links the tasks here.
    /// Best-effort and idempotent — a chip the user taps twice does no harm.
    func applyChip(_ chip: ClarifyChip, toTaskIds ids: [String], now: Date = Date()) async {
        guard !ids.isEmpty else { return }
        if case let .assignProject(name) = chip.action {
            await assignProject(named: name, toTaskIds: ids)
            return
        }
        try? await db.dbQueue.write { database in
            for id in ids {
                guard var task = try TaskItem.fetchOne(database, key: id) else { continue }
                task = chip.patch(task, now: now)
                try task.update(database)
            }
        }
    }

    /// Find-or-create a project by title (case-insensitive) and link the tasks to it. Reusing an
    /// existing container by name means tapping "Add to Groceries" twice doesn't spawn duplicates.
    private func assignProject(named name: String, toTaskIds ids: [String]) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await db.dbQueue.write { database in
            let existing = try Project
                .filter(Column("deleted") == false)
                .fetchAll(database)
                .first { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
            let project: Project
            if let existing { project = existing } else {
                project = Project(title: trimmed)
                try project.insert(database)
            }
            for id in ids {
                guard var task = try TaskItem.fetchOne(database, key: id) else { continue }
                task.projectId = project.id
                try task.update(database)
            }
        }
    }

    // MARK: Convenience (no-UI path: keep both, as before)

    /// One-shot capture for callers with no UI to prompt a duplicate choice (Siri's
    /// `DictateCaptureIntent`, tests): prepare, then finalize keeping every candidate. This
    /// reproduces the exact pre-blocking behavior — tasks inserted, similar ones surfaced as
    /// warnings on the `Outcome`.
    func process(rawInput: String, inputType: String) async throws -> Outcome {
        let prepared = try await prepare(rawInput: rawInput, inputType: inputType)
        // Empty resolutions => every candidate defaults to `.keepBoth`.
        return try await finalize(prepared, resolutions: [:])
    }

    // MARK: Calendar write

    /// For each task flagged as an appointment (and not already linked to an event), create a
    /// real calendar event and stamp its identifier onto the task. Best-effort: a task whose
    /// event can't be created (no permission, no due date) is returned unchanged, still saved as
    /// a normal task. Non-appointment tasks pass through untouched.
    private func attachCalendarEvents(to tasks: [TaskItem], appointmentTaskIds: Set<String>) async -> [TaskItem] {
        guard !appointmentTaskIds.isEmpty else { return tasks }
        var result = tasks
        for i in result.indices {
            guard appointmentTaskIds.contains(result[i].id),
                  result[i].calendarEventId == nil,
                  let start = DueDate.parse(result[i].dueDate) else { continue }
            if let eventId = await calendarWriter.createEvent(
                title: result[i].title,
                start: start,
                durationMinutes: result[i].effortMinutes
            ) {
                result[i].calendarEventId = eventId
            }
        }
        return result
    }

    // MARK: Merge / hierarchy helpers

    /// Backfill an existing task from a near-duplicate new capture without clobbering data
    /// the existing task already has: fill an empty due date (carrying its confidence) and an
    /// empty recurrence, and raise (never lower) priority. Narrow and deterministic by design.
    nonisolated static func merge(newTask: TaskItem, into existing: TaskItem) -> TaskItem {
        var merged = existing
        if merged.dueDate == nil, let due = newTask.dueDate {
            merged.dueDate = due
            merged.dueDateConfidence = newTask.dueDateConfidence
        }
        if merged.recurrenceRule == nil, let rule = newTask.recurrenceRule {
            merged.recurrenceRule = rule
        }
        if priorityRank(newTask.priority) > priorityRank(merged.priority) {
            merged.priority = newTask.priority
        }
        return merged
    }

    private nonisolated static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high": return 3
        case "low": return 1
        default: return 2       // medium / unknown
        }
    }

    /// Expand a set of task ids to include every descendant (via `parentTaskId`) among the
    /// given tasks — so dropping a parent also drops its subtasks. Iterates to a fixpoint to
    /// handle multi-level hierarchies.
    private nonisolated static func withDescendants(of ids: Set<String>, in tasks: [TaskItem]) -> Set<String> {
        var result = ids
        var changed = true
        while changed {
            changed = false
            for task in tasks {
                if let parent = task.parentTaskId, result.contains(parent), !result.contains(task.id) {
                    result.insert(task.id)
                    changed = true
                }
            }
        }
        return result
    }

    private static func encodeIds(_ ids: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Similarity

    /// Standard "'X' looks similar to existing 'Y'" phrasing, shared by the candidate scan
    /// and the legacy warning helper so both read identically.
    nonisolated static func warningText(newTitle: String, existingTitle: String) -> String {
        "“\(newTitle)” looks similar to existing “\(existingTitle)”"
    }

    /// Pair each new task with the existing open task it most resembles, keeping only pairs
    /// whose cosine similarity clears the threshold (spec §3.5). Testable with a fake embedder.
    nonisolated static func duplicateCandidates(
        newTasks: [TaskItem],
        existingTasks: [TaskItem],
        embedder: any TextEmbedding,
        threshold: Double = 0.85
    ) -> [DuplicateCandidate] {
        guard !existingTasks.isEmpty else { return [] }
        let existingVectors: [(task: TaskItem, vector: [Double])] = existingTasks.compactMap { task in
            embedder.vector(for: task.title).map { (task, $0) }
        }
        guard !existingVectors.isEmpty else { return [] }

        var candidates: [DuplicateCandidate] = []
        for newTask in newTasks {
            guard let v = embedder.vector(for: newTask.title) else { continue }
            if let best = existingVectors
                .map({ (task: $0.task, score: VectorMath.cosineSimilarity(v, $0.vector)) })
                .max(by: { $0.score < $1.score }),
               best.score >= threshold {
                candidates.append(DuplicateCandidate(
                    newTaskId: newTask.id,
                    newTitle: newTask.title,
                    existingTaskId: best.task.id,
                    existingTitle: best.task.title,
                    score: best.score
                ))
            }
        }
        return candidates
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
                warnings.append(warningText(newTitle: title, existingTitle: best.title))
            }
        }
        return warnings
    }
}
