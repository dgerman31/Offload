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
    /// Which extractor actually produced this — `finalize` writes it to `captures.model_source`.
    /// It used to hardcode `"foundation"` for every capture including the ones Gemini did, which
    /// made the column a constant and the "what did the cloud actually do" question unanswerable.
    var modelSource: String?
    /// A project name that was named but not applied — see `CaptureMapper.Result`. `finalize`
    /// turns this into `Outcome.suggestedProjectTitle` for the post-capture confirmation.
    var suggestedProjectTitle: String?
    /// True when this run is `CaptureRetrySweep` re-attempting an existing row. `finalize` uses it
    /// to retire the raw-text placeholder an older build's failed attempt left behind, so a
    /// successful retry replaces that task instead of duplicating it.
    var isRetry: Bool = false
    /// Titles of open tasks a new one restated word-for-word, so nothing was created for it. Not
    /// an error and not a warning — the point of saying it back is that "already on your list"
    /// is a *better* outcome than a second copy, and silence would look like the capture failed.
    var alreadyOnList: [String] = []
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
        /// Things this capture restated that were already open. See `PreparedCapture.alreadyOnList`.
        var alreadyOnList: [String] = []
        /// Ids of the tasks actually inserted — the targets a tapped chip patches.
        var insertedTaskIds: [String] = []
        /// The clarifying chips to offer for this capture (empty on a confident capture).
        var chips: [ClarifyChip] = []
        /// A project the capture named but that the tasks were *not* filed under — the prompt for
        /// "Want to file these under a project called X?". `nil` whenever a project was created and
        /// the tasks landed in it (nothing to ask), or when nothing named a project at all.
        /// Answering it is `assignProject(taskIds:title:)`.
        var suggestedProjectTitle: String?
        /// An existing project these tasks were filed into under a *different* spelling than the
        /// one spoken ("jury three" → "Jury 3"). The success screen reports it and offers an undo;
        /// `nil` when nothing matched, or when the name was already spelled that way.
        var filedUnderExistingProject: String?
        /// What this capture actually called the project — kept only so undoing the merge above
        /// can put the tasks in a project named the way the user said it.
        var capturedProjectName: String?
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
    /// nothing yet. The returned `PreparedCapture` must be handed to `finalize` to actually
    /// write anything.
    ///
    /// **A capture is never half-understood.** When Gemini can't run — no key, private mode, no
    /// network, no budget left — this throws `ExtractionUnavailable` and parks the row as `held`.
    /// It briefly did the opposite, saving the raw transcript as one plain task so the capture
    /// "succeeded", and that is precisely how "I left my jacket in school" became a task by that
    /// name: not a bad extraction, but no extraction at all, wearing a success's clothes. The raw
    /// row still persists, so the words are never lost; the UI keeps them in the capture box and
    /// says what happened, and the retry is the user's to make.
    ///
    /// `retrying` is the existing failed capture row when `CaptureRetrySweep` is re-attempting
    /// one. Passing it reuses that row instead of inserting a second one — otherwise every retry
    /// of a capture that keeps failing would leave another `failed` row behind, and the table
    /// would grow with each launch instead of the retry count converging on its ceiling.
    func prepare(rawInput: String, inputType: String, retrying: Capture? = nil) async throws -> PreparedCapture {
        let started = Date()

        // 1. Persist the raw capture first — never lose the user's words.
        let initial: Capture
        if let retrying {
            var claimed = retrying
            claimed.processingStatus = "processing"
            initial = claimed
            let toSave = claimed
            try await db.dbQueue.write { try toSave.update($0) }
        } else {
            initial = Capture(
                rawInput: rawInput,
                inputType: inputType,
                transcript: rawInput,
                processingStatus: "processing"
            )
            let toSave = initial
            try await db.dbQueue.write { try toSave.insert($0) }
        }

        // 2. Extract (typed output; no parsing). Gemini also returns clarifying chips and its
        // own command-vs-to-do judgment; the on-device fallback returns neither.
        let extraction: ExtractionResult
        do {
            extraction = try await extractor.extract(from: rawInput)
        } catch {
            // Nothing could extract. This used to mint a task from the raw transcript so the
            // capture "succeeded" — which is how "I left my jacket in school" ended up as a task
            // by that name: not a mis-extraction, but no extraction at all, dressed as one.
            //
            // Now nothing is created from words nothing understood. The raw row stays on disk
            // (so the text is never lost), and the reason travels up to the UI, which keeps the
            // capture in the box for a deliberate retry.
            //
            // Error *kind* only — never the capture's text, at any privacy level.
            Log.capture.error("Extraction unavailable (\(Self.errorKind(error), privacy: .public)) — holding the capture for the user to retry")
            var parked = initial
            // A sweep retrying an already-`failed` row must stay `failed`, or one transient
            // outage would park a legacy row forever. Only a fresh capture becomes `held` — the
            // status the sweep deliberately doesn't match, because its owner is looking at it.
            parked.processingStatus = retrying == nil ? "held" : "failed"
            if retrying != nil { parked.retryCount += 1 }
            let finalized = parked
            try? await db.dbQueue.write { try finalized.update($0) }
            throw (error as? ExtractionUnavailable)
                ?? ExtractionUnavailable.failed(error.localizedDescription)
        }

        do {
            let mapped = CaptureMapper.map(
                extraction.capture,
                sourceText: rawInput,
                isCommand: extraction.isProjectCommand
            )

            // 2b. Dedup check (spec §3.5): compare new tasks against existing open tasks by
            // embedding similarity. Rather than warn after the fact, surface candidates the
            // UI can block on before insertion.
            let allOpen = try await db.dbQueue.read { database in
                try TaskItem
                    .filter(Column("deleted") == false)
                    .filter(Column("status") != "completed")
                    .fetchAll(database)
            }
            // On a retry, the placeholder task this capture's own failed attempt left behind is
            // still sitting in `tasks`. It says the same thing as the capture we're re-extracting,
            // so it would match every new task and turn a recovery into a pile of duplicate
            // prompts. `finalize` retires it; the dedupe pass must not see it at all.
            let placeholders = Set(Self.decodeIds(retrying?.extractedTaskIds))
            let existing = placeholders.isEmpty ? allOpen : allOpen.filter { !placeholders.contains($0.id) }
            // Anything that's near-identical to something already open is dropped here rather
            // than becoming a question. The embedding pass below is for *similar* work — a real
            // judgement call the user should make — while this is for the same sentence said
            // twice, which is the normal consequence of an app whose whole point is that you say
            // things the moment they occur to you and then stop carrying them.
            let deduped = TaskMatcher.partition(newTasks: mapped.tasks, existing: existing)
            let alreadyOnList = deduped.duplicates.map(\.existing.title)

            let stored = UserDefaults.standard.double(forKey: Self.dedupeThresholdKey)
            let candidates = Self.duplicateCandidates(
                newTasks: deduped.create,
                existingTasks: existing,
                embedder: embedder,
                threshold: stored > 0 ? stored : 0.85
            )

            // Feature D: split commitment-shaped tasks (recurrence rules) into Routine models
            // so they block out the week rather than creating one-off tasks. The remaining
            // non-commitment tasks go through the normal pipeline.
            let commitment = CommitmentParser.parse(extraction.capture)
            let effectiveTasks = commitment.routines.isEmpty
                ? deduped.create
                : deduped.create.filter { task in
                    // Keep tasks whose titles weren't converted to routines. Compared
                    // case-insensitively on purpose: a routine's title is the raw extracted text
                    // while a task's has been through `CaptureMapper.actionTitle`, which
                    // capitalizes the first letter — so an exact match silently failed for every
                    // lowercase-initial capture, leaving both a routine *and* a duplicate task.
                    !commitment.routines.contains { $0.title.caseInsensitiveCompare(task.title) == .orderedSame }
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
                routines: commitment.routines,
                modelSource: extraction.modelSource,
                suggestedProjectTitle: mapped.suggestedProjectTitle,
                isRetry: retrying != nil,
                alreadyOnList: alreadyOnList
            )
        } catch {
            // Keep the raw transcript; mark failed and count the attempt, so `CaptureRetrySweep`
            // knows both that there's work here and when to stop coming back to it.
            var failed = initial
            failed.processingStatus = "failed"
            failed.retryCount += 1
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
        let fittedTasks = AutoFit.fitIntoToday(new: finalTasks, existing: existingTasks,
                                                startHour: DayPlanner.storedDayStartHour(),
                                                cutoffHour: DayPlanner.storedDayEndHour(),
                                                protected: ProtectedTime.stored())

        // 3. Persist surviving project + tasks and any merge backfills in one transaction.
        let project = prepared.project
        // Insert the project when it still has tasks, OR when it was intentionally created
        // empty ("create a project called X" — a container command, which maps to no tasks).
        // The only case we skip is a project whose tasks all got dropped by dedup resolution.
        let insertProject = project != nil && (!finalTasks.isEmpty || prepared.tasks.isEmpty)
        let backfillUpdates = Array(backfills.values)
        // Feature D: routines from commitment-shaped captures.
        let newRoutines = prepared.routines
        // A retry that finally extracted properly must replace the raw-text placeholder an older
        // build's failed attempt saved, not sit next to it. Only this capture's own recorded
        // tasks, and only ones the user hasn't already completed — if they acted on it, it was
        // real work and deleting it under them would be worse than a near-duplicate.
        //
        // Nothing creates placeholders any more (an unavailable extractor now throws rather than
        // inventing a task), so this only ever retires ones already on disk from before that
        // change — which is exactly why it has to stay.
        let retiredPlaceholderIds = prepared.isRetry
            ? Self.decodeIds(prepared.initial.extractedTaskIds)
            : []
        // Captured before the write: the closure is `@Sendable`, so it can't reach back into this
        // `@MainActor` service for its embedder.
        let embedder = self.embedder
        // The transaction *returns* what it learned about the project rather than writing out to
        // a captured `var`, for the same reason every other write here hands over immutable
        // copies — a `@Sendable` closure has no way to mutate main-actor state.
        let projectOutcome = try await db.dbQueue.write { database -> ProjectResolution? in
            for id in retiredPlaceholderIds {
                guard var stale = try TaskItem.fetchOne(database, key: id),
                      !stale.deleted, stale.status != "completed" else { continue }
                stale.deleted = true
                try stale.update(database)
            }
            // Reuse the project the user already has instead of minting a near-duplicate beside
            // it: capturing "more for the thesis" twice belongs in one project, and so does
            // "jury three" after "Jury 3". The tasks the mapper pointed at the new project get
            // re-pointed at the surviving one.
            var resolution: ProjectResolution?
            if insertProject, let project {
                resolution = try Self.findOrCreateProject(titled: project.title, in: database,
                                                          preferring: project, embedder: embedder)
            }
            let reusedProjectId: String? = {
                guard let surviving = resolution?.project.id, surviving != project?.id else { return nil }
                return surviving
            }()
            for fitted in fittedTasks {
                var task = fitted
                if let reusedProjectId, task.projectId == project?.id {
                    task.projectId = reusedProjectId
                }
                try task.insert(database)
            }
            for updated in backfillUpdates { try updated.update(database) }
            for routine in newRoutines { try routine.insert(database) }
            return resolution
        }

        // 4. Finalize the capture with instrumentation (spec §9).
        var done = prepared.initial
        done.processingMs = Int(Date().timeIntervalSince(prepared.startedAt) * 1000)
        // Record which tasks this capture owns, so a retry can retire an older build's raw-text
        // placeholder instead of duplicating it.
        done.extractedTaskIds = Self.encodeIds(finalTasks.map(\.id))
        // Reaching `finalize` now means an extraction genuinely happened — the unavailable path
        // throws out of `prepare` and never gets here — so there's no half-succeeded state left
        // to record.
        done.processingStatus = "done"
        done.processedAt = ISO8601DateFormatter().string(from: Date())
        done.modelSource = prepared.modelSource ?? ExtractionService.modelSource
        let finalized = done
        try await db.dbQueue.write { try finalized.update($0) }

        // Chips only make sense when there's a task to refine. A capture that produced a
        // container-only command, or whose tasks were all deduped away, gets none.
        let chips = finalTasks.isEmpty ? [] : prepared.chips
        // A merely *related* existing project is never merged into silently — it becomes the same
        // "file these under X?" offer a named-but-uncreated project already produces, so one card
        // and one code path answer both questions.
        let suggestion = projectOutcome?.possibleDuplicateTitle ?? Self.projectToConfirm(
            created: insertProject, named: project?.title,
            suggested: prepared.suggestedProjectTitle, savedTaskCount: finalTasks.count)

        return Outcome(
            addedTasks: finalTasks.count,
            taskTitles: finalTasks.map(\.title),
            // The surviving project's name, which is the one the tasks are actually in — saying
            // "jury three" back after filing into "Jury 3" would be a small lie.
            projectTitle: insertProject ? (projectOutcome?.project.title ?? project?.title) : nil,
            similarWarnings: warnings,
            alreadyOnList: prepared.alreadyOnList,
            insertedTaskIds: finalTasks.map(\.id),
            chips: chips,
            suggestedProjectTitle: suggestion,
            filedUnderExistingProject: projectOutcome?.mergedIntoTitle,
            capturedProjectName: projectOutcome?.mergedIntoTitle == nil ? nil : project?.title
        )
    }

    /// What (if anything) to ask the user about after a capture: "Want to file these under a
    /// project called X?".
    ///
    /// Nothing to ask when the project was created — the tasks are already in it — and nothing to
    /// ask when no task survived, since there'd be nothing to file. What's left is the two ways a
    /// named project quietly went nowhere: the container was skipped because dedup resolution took
    /// all its tasks, or the words named a project no extractor turned into one.
    nonisolated static func projectToConfirm(
        created: Bool, named: String?, suggested: String?, savedTaskCount: Int
    ) -> String? {
        guard savedTaskCount > 0, !created else { return nil }
        return named ?? suggested
    }

    // MARK: Chips — apply a tapped refinement to the just-saved tasks (no round-trip)

    /// Apply one clarifying chip's deterministic patch to the given tasks and persist it. Per-task
    /// patches (due date, priority, recurrence, category) come from `ClarifyChip.patch`; the one
    /// exception is `.assignProject`, which creates/reuses a container and links the tasks here.
    /// Best-effort and idempotent — a chip the user taps twice does no harm.
    func applyChip(_ chip: ClarifyChip, toTaskIds ids: [String], now: Date = Date()) async {
        guard !ids.isEmpty else { return }
        if case let .assignProject(name) = chip.action {
            // Best-effort: a chip is a convenience, so a failed write is logged, not surfaced.
            try? await assignProject(taskIds: ids, title: name)
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

    // MARK: Filing tasks under a project

    /// Find-or-create a project titled `title` (matched case-insensitively) and file the given
    /// tasks under it, in one transaction.
    ///
    /// This is the answer to `Outcome.suggestedProjectTitle` — the post-capture "Want to file these
    /// under X?" — and the same call the `assign_project` chip makes. Reusing an existing container
    /// by name is the whole point: confirming "Thesis" twice, or once from a chip and once from the
    /// prompt, must land in one project, not three identically-named ones. Idempotent, so a double
    /// tap does no harm.
    ///
    /// Throws rather than swallowing, so a caller showing a confirmation can tell the user it
    /// didn't take; `applyChip` keeps its best-effort behavior by ignoring the error.
    /// `matchExisting: false` skips the fuzzy tiers and files under a project spelled exactly as
    /// asked — what undoing an automatic merge means. Without it, undo would resolve the spoken
    /// name straight back into the project it was just separated from.
    func assignProject(taskIds: [String], title: String, matchExisting: Bool = true) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await db.dbQueue.write { database in
                let project: Project
                if matchExisting {
                    project = try Self.findOrCreateProject(titled: trimmed, in: database).project
                } else if let same = try Project.filter(Column("deleted") == false).fetchAll(database)
                    .first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    project = same
                } else {
                    project = Project(title: trimmed)
                    try project.insert(database)
                }
                for id in taskIds {
                    guard var task = try TaskItem.fetchOne(database, key: id) else { continue }
                    task.projectId = project.id
                    try task.update(database)
                }
            }
        } catch {
            // Counts and the error kind only. Not `localizedDescription`: a GRDB error carries the
            // failing SQL and its bound arguments, which here would be the user's own project
            // title and task text — exactly what must never reach the log, at any privacy level.
            Log.database.error("Filing \(taskIds.count, privacy: .public) task(s) under a project failed: \(Self.errorKind(error), privacy: .public)")
            throw error
        }
    }

    /// An error reduced to something safe to log: the SQLite result code, or the error's type name.
    /// Never its description — see the call site. Internal rather than private so callers outside
    /// this file (`CaptureViewModel`, which surfaces the same project-filing failures) can log
    /// safely instead of reaching for `localizedDescription`.
    nonisolated static func errorKind(_ error: Error) -> String {
        if let dbError = error as? DatabaseError { return "sqlite \(dbError.resultCode.rawValue)" }
        return String(describing: type(of: error))
    }

    /// The single find-or-create rule, shared by `finalize`'s insert and `assignProject` so the two
    /// can't drift into different ideas of what "same project" means. Matching is case-insensitive
    /// over live (non-deleted) projects.
    ///
    /// `preferring` lets `finalize` insert the exact `Project` the mapper built — same id — so the
    /// tasks already pointing at it need no re-pointing; everyone else gets a fresh row.
    /// `nonisolated` because GRDB's write closure is `@Sendable`.
    /// Resolve `title` to a project, reusing an existing one when it's the same project said
    /// differently rather than minting a near-duplicate beside it.
    ///
    /// The old rule here was `caseInsensitiveCompare`, which meant "Jury 3", "jury3", "Jury-3"
    /// and "jury three" were four projects holding slices of one piece of work — the normal
    /// outcome for spoken capture, since dictation spells numbers out and drops punctuation.
    /// `ProjectMatcher` grades the match instead: exact and close matches are reused (a close one
    /// reports itself so the user can undo), while a merely *related* name creates what they
    /// actually said and leaves the merge as a question.
    ///
    /// `embedder` is optional — without one only the deterministic tiers run, which is what the
    /// chip and confirmation paths want (the user already named the project explicitly there).
    private nonisolated static func findOrCreateProject(
        titled title: String, in database: Database, preferring candidate: Project? = nil,
        embedder: (any TextEmbedding)? = nil
    ) throws -> ProjectResolution {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try Project.filter(Column("deleted") == false).fetchAll(database)

        if let match = ProjectMatcher.best(for: trimmed, among: existing, embedder: embedder) {
            switch match.confidence {
            case .exact:
                return ProjectResolution(project: match.project)
            case .close:
                // Same project, different spelling. Say so — silently absorbing someone's words
                // into a name they didn't use is the kind of "helpful" that reads as a bug.
                return ProjectResolution(project: match.project, mergedIntoTitle: match.project.title)
            case .related:
                let project = candidate ?? Project(title: trimmed)
                try project.insert(database)
                return ProjectResolution(project: project,
                                         possibleDuplicateTitle: match.project.title)
            }
        }

        let project = candidate ?? Project(title: trimmed)
        try project.insert(database)
        return ProjectResolution(project: project)
    }

    // MARK: Convenience (no-UI path: keep both, as before)

    /// One-shot capture for callers with no UI to prompt a duplicate choice (Siri's
    /// `DictateCaptureIntent`, tests): prepare, then finalize keeping every candidate. This
    /// reproduces the exact pre-blocking behavior — tasks inserted, similar ones surfaced as
    /// warnings on the `Outcome`.
    func process(rawInput: String, inputType: String, retrying: Capture? = nil) async throws -> Outcome {
        let prepared = try await prepare(rawInput: rawInput, inputType: inputType, retrying: retrying)
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

    private nonisolated static func encodeIds(_ ids: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The inverse of `encodeIds`, for reading back which tasks a previous attempt at this capture
    /// saved. Tolerant by design: a null or malformed column is simply "none".
    nonisolated static func decodeIds(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
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

/// What resolving a spoken project name against the existing ones produced.
///
/// File-scope rather than nested inside `CaptureService`, because it is returned *out of* a
/// GRDB write closure — which is `@Sendable`, so the value has to be `Sendable` with no
/// dependence on how global-actor isolation does or doesn't reach a type nested in a
/// `@MainActor` class.
struct ProjectResolution: Sendable {
    let project: Project
    /// The existing project's title, when a *differently spelled* name was matched into it
    /// ("jury three" → "Jury 3"). This is what the UI reports as "Filed under X" and what an
    /// undo separates again. `nil` when the name was new, or already spelled the same way.
    var mergedIntoTitle: String?
    /// An existing project that reads like the same thing but wasn't certain enough to file
    /// into. The capture still creates what the user said; the UI asks about merging.
    var possibleDuplicateTitle: String?
}
