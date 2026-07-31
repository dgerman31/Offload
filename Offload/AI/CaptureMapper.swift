import Foundation

/// Converts the model's `ExtractedCapture` into domain records ready for SQLite.
/// Pure and deterministic — no model calls — so it's fully unit-testable.
enum CaptureMapper {

    /// The valid category set (spec §4, feature 3). Anything off-list falls back to "Other".
    static let categories: Set<String> = [
        "Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"
    ]
    static let priorities: Set<String> = ["high", "medium", "low"]

    /// A *suggested* context-tag vocabulary the prompt steers the model toward. No longer a
    /// hard filter: Gemini can coin a more useful, specific tag ("kitchen", "school", "doctor")
    /// than this closed list allows, and silently deleting anything novel made captures feel
    /// dumber than the model actually is. Kept only as documentation of the house style.
    static let suggestedContextTags: Set<String> = [
        "home", "work", "car", "outside", "store", "gym", "phone", "computer", "meeting", "errands"
    ]

    /// A sane upper bound on a single effort estimate (24h). Not second-guessing the model's
    /// judgment — just a data-integrity rail so a wild value can't poison the planner's math.
    static let maxEffortMinutes = 24 * 60

    struct Result {
        var project: Project?
        var tasks: [TaskItem]
        /// Ids of tasks the model classified as real calendar appointments *and* that carry a
        /// due date — the ones the capture pipeline turns into EventKit events (spec §3.3 write).
        var appointmentTaskIds: Set<String> = []
        /// A project name that was *named but not applied*: either the model suggested one the
        /// mapper declined to auto-create, or the raw words plainly refer to a project ("the Jury 3
        /// project") that no extractor turned into a container. Always `nil` when `project` is
        /// non-nil — there's nothing to ask about once the tasks are already filed. The capture
        /// pipeline surfaces this so the UI can offer it rather than silently guessing.
        var suggestedProjectTitle: String?
    }

    /// Build a `Project` and the `TaskItem`s, linked to it. `now` grounds the due-date priority
    /// guardrail. `isCommand` is the extractor's own judgment on command-vs-to-do (Gemini) —
    /// `nil` means "unjudged", so we fall back to a lightweight regex on `sourceText`.
    ///
    /// Philosophy: Gemini is a frontier model with real judgment, so this mapper trusts its
    /// output and keeps only true safety/data-integrity backstops (calendar-write gating, enum
    /// normalization, no-night-scheduling, effort clamp). It no longer fact-checks the model's
    /// dates, effort, tags, or subtasks against static word lists — that steering lives in the
    /// system prompt now, where a smart model can reason about it instead of a regex guessing.
    static func map(
        _ extracted: ExtractedCapture,
        now: Date = Date(),
        calendar: Calendar = .current,
        sourceText: String? = nil,
        isCommand: Bool? = nil,
        profile: LearnedProfile = .stored()
    ) -> Result {
        // Is the user talking TO the app ("create a project called X" — a command) or ABOUT
        // their work ("I need to create a project" — a to-do)? Gemini decides this directly; the
        // regex is only a fallback for the on-device path that can't.
        let containerCommand = isCommand ?? (sourceText.map(isContainerCommand) ?? false)

        let projectName: String? = {
            if let name = extracted.suggestedProject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty { return name }
            // An explicit command whose name the model failed to pull out — recover it from
            // the words themselves ("...called X").
            if containerCommand { return sourceText.flatMap { containerName(from: $0) } }
            return nil
        }()

        let project: Project? = {
            guard let name = projectName, !name.isEmpty else { return nil }
            // Trust a suggested project: the model only names one for a genuine endeavour (the
            // prompt tells it not to over-organize a lone errand), and a confident single-task
            // project is often correct. The one thing we won't do is spin up an *empty* project
            // from noise — a name needs either a command behind it or at least one real task.
            guard containerCommand || !extracted.tasks.isEmpty else { return nil }
            return Project(title: name)
        }()

        // The user's actual complaint: "projects aren't created from a capture that specifically
        // includes project names." The on-device model very rarely fills `suggestedProject` (it's
        // a small model with a crowded window), and the command regex only fires on an imperative
        // "create a project called X" — so "working on the Jury 3 project, I need to draft the
        // opening" produced tasks and no container, with nothing anywhere saying why.
        //
        // Rather than guess and silently create one from a regex (a wrong project is worse than
        // none), recover the name and hand it up as a *suggestion* the UI can confirm. Only when
        // nothing was actually created — once tasks are filed, there is nothing to ask about.
        let suggestion: String? = project == nil
            ? (projectName ?? sourceText.flatMap { mentionedProjectName(in: $0) })
            : nil

        var tasks: [TaskItem] = []
        var appointmentTaskIds: Set<String> = []
        for t in extracted.tasks {
            // When the user commanded "create a project", the creation IS the action — drop any
            // redundant "Create project X" task the model tacked on.
            if containerCommand, isCreateContainerTask(t.title) { continue }
            let resolved = resolveDue(t.dueDate, calendar: calendar)
            let dueDate = resolved.value
            let isAllDay = resolved.isAllDay
            let cleanTitle = actionTitle(t.title)
            // A user-stated clock time is a commitment: "meeting at 3" must STAY at 3. Pin it so
            // the planner and the self-healing timeline treat it as a fixed anchor and never
            // reflow it — matching manual add/edit, which already pin any hand-picked time. (Only
            // a whole-day intention stays soft and reflowable.) The stricter isRealAppointment
            // gate below still governs the consequential part — writing to the real calendar.
            let hasStatedTime = dueDate != nil && !isAllDay
            // The model's guess, corrected by what this person's own history says about work
            // like this. See `learnedEffort` — it either finds a matching phrase you've timed
            // before, or applies your measured drift, or leaves the guess alone.
            let category = normalizedCategory(t.category)
            let effort = learnedEffort(title: cleanTitle,
                                       modelEstimate: clampedEffort(t.effortMinutes),
                                       category: category,
                                       profile: profile)
            let parent = TaskItem(
                title: cleanTitle,
                descriptionText: nonEmpty(t.details),
                category: category,
                priority: resolvedPriority(normalizedPriority(t.priority), dueDate: dueDate, now: now, calendar: calendar),
                projectId: project?.id,
                dueDate: dueDate,
                dueDateConfidence: dueDate == nil ? nil : 0.5,
                recurrenceRule: nonEmpty(t.recurrenceRule),
                contextTags: encodeTags(t.contextTags),
                effortMinutes: effort.minutes,
                metadata: effort.note,
                people: People.encode(t.people),
                deadline: DueDate.normalizeLocal(t.deadline, timeZone: calendar.timeZone),
                dueIsAllDay: isAllDay,
                pinned: hasStatedTime
            )
            tasks.append(parent)
            // Writing to someone's real calendar needs more than the model's say-so: a genuine
            // time, and a title that isn't itself about *arranging* the thing.
            if isRealAppointment(title: parent.title, isAppointment: t.isAppointment,
                                 dueDate: dueDate, isAllDay: isAllDay) {
                appointmentTaskIds.insert(parent.id)
            }

            // Hierarchical extraction (spec feature 1): the model decides *whether* to
            // decompose; here we just clean what it returned (dedupe, drop restatements of the
            // parent). Children inherit the parent's category/priority/context. Cleaning titles
            // BEFORE the pass lets fluff-only variants collapse as duplicates.
            for title in cleanSubtasks(parentTitle: parent.title, subtasks: t.subtasks.map(actionTitle)) {
                tasks.append(TaskItem(
                    title: title,
                    category: parent.category,
                    priority: parent.priority,
                    parentTaskId: parent.id,
                    projectId: project?.id,
                    contextTags: parent.contextTags
                ))
            }
        }
        return Result(project: project, tasks: tasks, appointmentTaskIds: appointmentTaskIds,
                      suggestedProjectTitle: suggestion)
    }

    /// Minimal subtask cleanup. The restraint ("only decompose when there are genuinely distinct
    /// steps") now lives in the system prompt, where a smart model decides it — so this no longer
    /// nukes every subtask when there's only one. It just does the mechanical hygiene a model
    /// can't guarantee: drop blanks, collapse duplicates, and drop any subtask that merely
    /// restates the parent errand (parent "Go to the store to buy milk" / subtask "Buy milk").
    static func cleanSubtasks(parentTitle: String, subtasks: [String]) -> [String] {
        let parent = normalizedForComparison(parentTitle)
        var seen = Set<String>()
        var kept: [String] = []
        for raw in subtasks {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let norm = normalizedForComparison(title)
            guard !norm.isEmpty else { continue }
            // Drop anything that restates the parent errand (either direction).
            if norm == parent || (!parent.isEmpty && (parent.contains(norm) || norm.contains(parent))) { continue }
            guard seen.insert(norm).inserted else { continue }   // collapse duplicates
            kept.append(title)
        }
        // A *single* surviving step that says the parent's errand back in different words isn't a
        // decomposition — it's one task padded into two, and it's what the user hit: "Enter REDCap
        // data" (4h) with one step, "Put REDCap data in" (15 min). The containment check above
        // can't see it, because neither string contains the other. Deliberately limited to the
        // lone-step case: two or more steps sharing the parent's noun ("Pack for the trip" →
        // "Pack chargers", "Pack toiletries") is normal, useful decomposition, and the prompt
        // already tells the model a single-step task needs no steps at all.
        if kept.count == 1, restatesParent(kept[0], parent: parentTitle) { return [] }
        return kept
    }

    /// Grammatical filler that carries no errand — stripped before comparing two titles for
    /// meaning, so "Put REDCap data **in the** spreadsheet" isn't held apart from "Enter REDCap
    /// data" by words neither of them is about.
    private static let restatementStopWords: Set<String> = [
        "a", "an", "the", "to", "for", "of", "in", "on", "at", "with", "and", "or", "my", "our",
        "your", "it", "its", "this", "that", "these", "those", "into", "from", "up", "out",
        "about", "all", "some", "any", "then", "so", "is", "are", "be"
    ]

    /// The words a title is actually *about*: its tokens minus the leading action verb and minus
    /// filler. "Enter REDCap data" and "Putting REDCap data in" both reduce to `{redcap, data}`,
    /// which is exactly the signal — the same errand, said twice.
    static func contentWords(_ title: String) -> Set<String> {
        var tokens = normalizedForComparison(title).split(separator: " ").map(String.init)
        if tokens.count > 1 { tokens.removeFirst() }   // the action verb, which always differs
        return Set(tokens.filter { !restatementStopWords.contains($0) && $0.count > 1 })
    }

    /// Does `step` restate `parent`? True when most of either title's content is the other's —
    /// asymmetric on purpose, since a restatement can be either shorter ("REDCap data") or longer
    /// ("Put the REDCap data in the spreadsheet") than what it restates.
    static func restatesParent(_ step: String, parent: String) -> Bool {
        let parentWords = contentWords(parent)
        let stepWords = contentWords(step)
        guard !parentWords.isEmpty, !stepWords.isEmpty else { return false }
        let shared = Double(parentWords.intersection(stepWords).count)
        return shared / Double(parentWords.count) >= 0.6 || shared / Double(stepWords.count) >= 0.6
    }

    /// Lowercased, alphanumerics-and-spaces-only, whitespace-collapsed form for the restraint
    /// comparison above — so punctuation and casing don't hide a restatement.
    private static func normalizedForComparison(_ s: String) -> String {
        let cleaned = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // MARK: Helpers

    /// Accept the built-in set plus anything the user has defined for themselves; anything
    /// else the model invents still falls back to "Other".
    static func normalizedCategory(_ raw: String, allowed: [String]? = nil) -> String {
        let valid = allowed ?? CustomCategories.all()
        if let match = valid.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return match
        }
        return categories.contains(raw) ? raw : "Other"
    }

    static func normalizedPriority(_ raw: String) -> String {
        priorities.contains(raw) ? raw : "medium"
    }

    /// A light last-resort cleanup, NOT the primary mechanism — the intent-extraction prompt is
    /// what turns "keep forgetting to call mom" into "Call mom". This only sweeps up the most
    /// common meta-prefixes a weaker fallback model might parrot ("remember to", "need to"), and
    /// capitalizes the first letter. Idempotent on an already-clean title, so Gemini's output
    /// passes through untouched; it can't generalize the way the model can, so it stays small.
    /// Falls back to the trimmed original rather than ever producing an empty title.
    static func actionTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fluff = [
            "remember to ", "don't forget to ", "dont forget to ",
            "i need to ", "i have to ", "need to ", "have to ", "try to "
        ]
        var title = trimmed
        var stripped = true
        while stripped {
            stripped = false
            for prefix in fluff where title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        guard !title.isEmpty else { return trimmed }
        if let first = title.first, first.isLowercase {
            title = String(first).uppercased() + title.dropFirst()
        }
        return title
    }

    /// Decide what a model-supplied due date actually means.
    ///
    /// We trust the model on *whether* there's a date (the prompt says "null unless they said
    /// when", and Gemini doesn't invent them); this only decides *how to store* one it gave us.
    /// Three outcomes: none (the model returned nothing parseable), a whole-day intention (a date
    /// with no meaningful hour, or an hour nobody works), or a real moment. The whole-day case is
    /// the important one — "Friday" should stay Friday, not become Friday at midnight — and the
    /// sleeping-hour demotion is a real safety rail: nothing is ever *scheduled* at 2 AM.
    static func resolveDue(
        _ raw: String?,
        calendar: Calendar = .current
    ) -> (value: String?, isAllDay: Bool) {
        // Local-first: the model means the user's wall clock, not UTC. Use the calendar's zone
        // so this is deterministic in tests and correct in the user's real timezone.
        guard let parsed = DueDate.parseLocal(raw, timeZone: calendar.timeZone)
        else { return (nil, false) }

        // Midnight almost always means "that day", not "at 00:00".
        let components = calendar.dateComponents([.hour, .minute], from: parsed)
        let looksDayOnly = (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0

        // A time in the small hours is a resolution artefact, not an intention.
        if looksDayOnly || isSleepingHour(parsed, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: parsed)
            return (DueDate.canonicalString(from: dayStart), true)
        }
        return (DueDate.canonicalString(from: parsed), false)
    }

    // MARK: Command vs. to-do

    /// Nouns that name a container the app can make.
    private static let containerNouns = ["project", "list", "folder", "category"]
    /// Verbs that create one.
    private static let makeVerbs = ["create", "make", "add", "start", "set up", "setup", "new"]

    /// Is the capture a direct instruction TO the app to create a container, rather than the
    /// user describing something they need to do?
    ///
    /// The distinction is grammatical: a command leads with the verb ("create a project called
    /// X"), while a to-do names a subject first ("I need to create a project"). Because a to-do
    /// starts with "I" / "we" / a modal, anchoring the match to the start of the sentence
    /// cleanly separates the two — "I need to create a project" simply doesn't match.
    static func isContainerCommand(_ text: String) -> Bool {
        var lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip polite lead-ins that are still aimed at the app.
        for lead in ["please ", "can you ", "could you ", "hey ", "ok ", "okay ", "just "] {
            if lower.hasPrefix(lead) { lower = String(lower.dropFirst(lead.count)) }
        }
        let verbs = makeVerbs.joined(separator: "|")   // "set up" keeps its space — fine in a regex
        let nouns = containerNouns.joined(separator: "|")
        let pattern = "^(\(verbs))\\s+(a\\s+|an\\s+|the\\s+)?(new\\s+)?(\(nouns))\\b"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    /// Does a task title just restate "create the container"? Such a task is redundant once the
    /// container itself is being made.
    static func isCreateContainerTask(_ title: String) -> Bool {
        let lower = title.lowercased()
        return makeVerbs.contains { lower.hasPrefix($0) } && containerNouns.contains { lower.contains($0) }
    }

    /// Pull a container's name out of the raw command ("...called X", "...named X"), stopping
    /// at the first clause boundary so trailing tasks don't get swept into the title.
    static func containerName(from text: String) -> String? {
        let lower = text
        for marker in [" called ", " named ", " titled ", " for "] {
            guard let r = lower.range(of: marker, options: .caseInsensitive) else { continue }
            var rest = String(lower[r.upperBound...])
            if let cut = rest.range(of: #"[,.;:]|\band\b|\bthen\b|\bi need\b|\bi have\b|\bi want\b|\bi gotta\b|\bi should\b"#,
                                    options: [.regularExpression, .caseInsensitive]) {
                rest = String(rest[..<cut.lowerBound])
            }
            let name = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 60 else { continue }
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return nil
    }

    /// Words that are a grammatical filler rather than a name, so "the same project" or "the new
    /// list" never becomes a container called "Same" or "New".
    private static let nonNames: Set<String> = [
        "new", "same", "whole", "next", "last", "first", "second", "third", "other", "another",
        "todo", "to do", "task", "tasks", "big", "little", "main", "only", "entire", "current",
        "that", "this", "these", "those", "usual", "one"
    ]

    /// Recover a project name the user plainly *referred to* without commanding one: "the Jury 3
    /// project", "my thesis project", "the shopping list". Deliberately narrow — it needs the
    /// container noun ("project"/"list") right there in the words, because this feeds a suggestion
    /// the user confirms, and a suggestion that's wrong half the time is worse than none.
    ///
    /// Returns the name only (no trailing "project"), title-cased on the first letter to match how
    /// `containerName` and the model spell one.
    static func mentionedProjectName(in text: String) -> String? {
        // (the|my|our|your) <up to four name words> (project|list)
        let word = "[\\p{L}\\p{N}][\\p{L}\\p{N}'’-]*"
        let pattern = "\\b(?:the|my|our|your)\\s+(\(word)(?:\\s+\(word)){0,3})\\s+(?:project|list)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }

        var name = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim leading filler so "the new kitchen project" suggests "Kitchen", not "New kitchen".
        while let head = name.split(separator: " ").first, nonNames.contains(head.lowercased()) {
            name = String(name.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        }
        guard name.count >= 2, name.count <= 60, !nonNames.contains(name.lowercased()) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Hours nobody means to be working. A derived time landing here is a bug, not a plan — so a
    /// due time that resolves into the small hours is demoted to a whole-day intention. A genuine
    /// data-quality rail (a task should never be *scheduled* at 2 AM), kept regardless of model.
    static let sleepingHours = 22..<7

    static func isSleepingHour(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }

    /// Keep the model's effort estimate, clamped to a sane range. Trusting Gemini to infer that
    /// "review the deck" is ~20 min (the prompt asks it to) is the point; this is only the
    /// data-integrity floor/ceiling so a stray 0 or a wild 99999 can't corrupt the planner.
    static func clampedEffort(_ minutes: Int?) -> Int? {
        guard let m = minutes, m > 0 else { return nil }
        return min(m, maxEffortMinutes)
    }

    /// Verbs that mean "arrange this" rather than "this is arranged". A task whose whole
    /// point is *to book a thing* has no time yet, so it must never become a calendar event —
    /// "Schedule a meeting with Dr. Bannazadeh" is a to-do, not a meeting.
    private static let arrangingVerbs = [
        "schedule", "book", "arrange", "set up", "setup", "organise", "organize",
        "plan ", "find a time", "reschedule", "confirm", "ask about", "email about",
        "call to", "reach out", "follow up"
    ]

    /// Should this become a real calendar event? Only when the model says it's an appointment,
    /// it has a genuine time (not a whole-day placeholder), and the title isn't about
    /// *arranging* something. Writing to someone's real calendar deserves all three.
    static func isRealAppointment(title: String, isAppointment: Bool, dueDate: String?, isAllDay: Bool) -> Bool {
        guard isAppointment, !isAllDay, dueDate != nil else { return false }
        let lower = title.lowercased()
        return !arrangingVerbs.contains { lower.hasPrefix($0) || lower.contains(" \($0)") }
    }

    /// Guardrail against under-prioritized imminent work: something due today or already
    /// overdue is never "low", even when the user's phrasing was casual (a common source of
    /// the model mis-calling priority). Only lifts low→medium; the model's high/medium calls
    /// and anything without a near-term due date are left untouched.
    static func resolvedPriority(_ priority: String, dueDate: String?, now: Date, calendar: Calendar = .current) -> String {
        guard priority == "low", let due = DueDate.parse(dueDate) else { return priority }
        let todayOrOverdue = calendar.isDate(due, inSameDayAs: now) || due < now
        return todayOrOverdue ? "medium" : "low"
    }

    /// Encode context tags as a JSON array string: lowercased, de-duplicated, order-preserving.
    /// No longer filtered against a closed vocabulary — Gemini can coin a more useful, specific
    /// tag ("kitchen", "school", "doctor") than the old ten-word list allowed, and deleting
    /// anything novel just made captures dumber. Only the mechanical hygiene remains: trim,
    /// lowercase, dedupe, and a light sanity bound (a real word, not a sentence). Returns nil
    /// when nothing valid remains.
    static func encodeTags(_ tags: [String]) -> String? {
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { isReasonableTag($0) && seen.insert($0).inserted }
        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// A tag is a short label, not a phrase. Accept anything that's non-empty, not too long, and
    /// a single token — the light sanity bound that replaced the closed vocabulary.
    static func isReasonableTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 24 else { return false }
        return !tag.contains(" ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Correct the model's estimate with this person's own history, and leave a note saying why.
    ///
    /// Two sources, in order of how specific they are:
    ///
    /// 1. **A phrase you've actually timed.** If you've done "review lecture" fourteen times and it
    ///    takes fifty minutes, that beats any general prior — it's the same work, measured.
    /// 2. **Your measured drift.** Failing a specific match, if your Work reliably runs 40% long,
    ///    stretch the guess by 40%.
    ///
    /// Neither fires without evidence, and neither fires for a small disagreement: silently moving
    /// 30 minutes to 32 is noise wearing the costume of intelligence, and it spends trust for
    /// nothing. When something does change, the original is recorded so the task can say what it
    /// did and be put back in one tap.
    static func learnedEffort(
        title: String,
        modelEstimate: Int?,
        category: String?,
        profile: LearnedProfile
    ) -> (minutes: Int?, note: String?) {
        if let suggestion = EstimatePriors.suggestion(for: title, modelEstimate: modelEstimate,
                                                      priors: profile.estimatePriors) {
            // Always noted, even when the model offered no estimate to revert to. The note isn't
            // only an undo affordance — it's also what stops the planner applying drift on top of
            // a figure that's already measured time rather than a guess.
            return (suggestion.minutes,
                    LearnedEstimate.encode(original: suggestion.replaced, reason: suggestion.reason))
        }
        guard let modelEstimate,
              let adjustment = profile.adjustment(minutes: modelEstimate, category: category)
        else { return (modelEstimate, nil) }
        return (adjustment.adjusted,
                LearnedEstimate.encode(original: adjustment.base, reason: adjustment.reason))
    }

}
