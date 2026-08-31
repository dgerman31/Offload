import Foundation

/// Extraction via Gemini. Produces the same `ExtractedCapture` the on-device path does, so
/// everything downstream — `CaptureMapper` and its deterministic guards — is unchanged. A far
/// larger model with a huge context window means the failures that plagued the small on-device
/// model (invented tasks, dropped context, the 4k-token overflow) simply don't happen here.
@MainActor
struct GeminiExtractionService {

    var client: GeminiClient
    /// Everything the model should know about this person's world before it reads their sentence —
    /// who they are, what projects they're running, what they've been doing, what's outstanding,
    /// their vocabulary, and where the model has previously been wrong about them. Assembled by
    /// `CaptureContext`, which is where the ordering and the token budget are decided.
    var context: () async -> String?
    var categories: [String]

    /// The value written to `captures.model_source` for work this extractor did. The vocabulary
    /// (`foundation` | `mlx` | `cloud`) is documented on `Capture.modelSource`.
    nonisolated static let modelSource = "cloud"

    // MARK: DTOs — plain Codable, decoupled from Apple's @Generable ExtractedCapture.

    private struct GCapture: Codable {
        /// A private scratchpad the model fills FIRST (it's first in propertyOrdering, so the
        /// model literally reasons before it structures). The app ignores it — it exists only to
        /// let the model think, which measurably improves the tasks that follow.
        var reasoning: String?
        var summary: String?
        var suggestedProject: String?
        /// Gemini's own command-vs-to-do judgment — replaces the old brittle regex in the mapper.
        var isCommand: Bool?
        var tasks: [GTask]
        /// 0–4 fast refinements for anything genuinely ambiguous; omitted on a confident capture.
        var chips: [GChip]?
        /// How sure the model is it read this right, 0…1. Drives whether the result screen asks.
        var confidence: Double?
    }
    private struct GTask: Codable {
        /// What kind of thing this is — the judgement that decides whether it may be scheduled and
        /// whether the model was allowed to reword it. See `CaptureKind`.
        var kind: String?
        var title: String
        var details: String?
        var category: String
        var priority: String
        var contextTags: [String]
        var people: [String]
        var dueDate: String?
        var deadline: String?
        var recurrenceRule: String?
        var effortMinutes: Int?
        var isAppointment: Bool
        var subtasks: [String]
    }
    /// A clarifying chip on the wire: a button label plus a closed action key and optional value.
    private struct GChip: Codable {
        var label: String
        var action: String
        var value: String?
    }

    /// The response schema, mirroring `ExtractedCapture`. Kept in lock-step with the DTOs above.
    private static func schema(categories: [String]) -> GSchema {
        let task: GSchema = .object(properties: [
            // First in the ordering, and required: Gemini generates fields in this order, so the
            // model has to commit to *what kind of thing this is* before it writes a title — which
            // is what makes the fidelity rule (reword a task, never reword an idea) apply at the
            // moment the title is actually being written.
            .init("kind", .string(enumValues: CaptureKind.wireValues)),
            .init("title", .string()),
            .init("details", .string(nullable: true)),
            .init("category", .string(enumValues: categories)),
            .init("priority", .string(enumValues: ["high", "medium", "low"])),
            .init("contextTags", .array(.string())),
            .init("people", .array(.string())),
            .init("dueDate", .string(nullable: true)),
            .init("deadline", .string(nullable: true)),
            .init("recurrenceRule", .string(nullable: true)),
            .init("effortMinutes", .integer(nullable: true)),
            .init("isAppointment", .boolean),
            .init("subtasks", .array(.string()))
        ], required: ["kind", "title", "category", "priority", "contextTags", "people", "isAppointment", "subtasks"])

        let chip: GSchema = .object(properties: [
            .init("label", .string()),
            .init("action", .string(enumValues: [
                "due_today", "due_tomorrow", "due_this_week", "due_none",
                "priority_high", "repeat_weekly", "set_category", "assign_project", "set_kind"
            ])),
            .init("value", .string(nullable: true))
        ], required: ["label", "action"])

        // Ordering matters: Gemini generates fields in this order, so `reasoning` first means the
        // model thinks before it commits to how the capture is structured.
        return .object(properties: [
            .init("reasoning", .string(nullable: true)),
            .init("summary", .string(nullable: true)),
            .init("isCommand", .boolean),
            .init("suggestedProject", .string(nullable: true)),
            .init("tasks", .array(task)),
            .init("chips", .array(chip)),
            .init("confidence", .number(nullable: true))
        ], required: ["tasks", "isCommand"])
    }

    func extract(from transcript: String, now: Date = Date()) async throws -> ExtractionResult {
        var system = Self.systemPrompt(now: now, categories: categories)
        // Appended after the instructions rather than before: the rules are what the model is for,
        // and the world is what it applies them to. `CaptureContext` orders the blocks inside.
        if let briefing = await context() {
            system += "\n\n---\n\n# What you know about this person\n\n" + briefing
        }

        let capture = try await client.generate(
            system: system,
            prompt: transcript,
            schema: Self.schema(categories: categories),
            as: GCapture.self,
            temperature: 0.2
        )
        let domain = Self.domain(capture)
        return ExtractionResult(
            capture: domain,
            chips: ClarifyChip.withKindFallback(Self.chips(capture.chips), capture: domain),
            isProjectCommand: capture.isCommand,
            modelSource: Self.modelSource
        )
    }

    /// Map the wire DTO to the domain type the rest of the app already understands.
    private static func domain(_ g: GCapture) -> ExtractedCapture {
        ExtractedCapture(
            summary: g.summary,
            tasks: g.tasks.map { t in
                ExtractedTask(
                    kind: CaptureKind.parse(t.kind).rawValue,
                    title: t.title, details: t.details, category: t.category, priority: t.priority,
                    contextTags: t.contextTags, people: t.people, dueDate: t.dueDate,
                    deadline: t.deadline, recurrenceRule: t.recurrenceRule, effortMinutes: t.effortMinutes,
                    isAppointment: t.isAppointment, subtasks: t.subtasks
                )
            },
            suggestedProject: g.suggestedProject,
            confidence: g.confidence
        )
    }

    /// Map wire chips to domain chips, dropping any whose action key we don't recognize (a chip
    /// writes to a task, so an unknown suggestion is discarded, not trusted) and capping at four.
    private static func chips(_ wire: [GChip]?) -> [ClarifyChip] {
        guard let wire else { return [] }
        return wire.prefix(4).compactMap { c in
            let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, let action = ChipAction.parse(key: c.action, value: c.value) else { return nil }
            return ClarifyChip(label: label, action: action)
        }
    }

    /// The instructions. Gemini has a large context window, so this reads as a full briefing to a
    /// capable assistant — its goal, its freedom, and how to think — rather than a checklist of
    /// prohibitions written to fence in a weak model. The app enforces only a few hard safety
    /// rails; the quality of everything else lives here.
    static func systemPrompt(now: Date, categories: [String]) -> String {
        let (localNow, tz) = Self.localNow(now)
        return """
        You are the intelligence inside Offload. Someone speaks a thought out loud — rushed, half-formed, mid-stream — and hands it to you so they can stop holding it. Your job is to catch it and give it back as structure they can act on, so their head is empty and nothing is lost.

        Think of yourself as a chief of staff who knows this person. They say "ugh I still have to sort out mom's birthday and grab stuff for dinner" and you just handle it — the right tasks, grouped the way they'd actually do them, weighted the way they actually matter. You have real judgment. Use it. The instructions below tell you what the fields mean and what the system needs to be literally true; almost everything else is a call you get to make.

        ---

        ## The one thing to get right

        **Capture what they meant to do, not what they said.** "Left my jacket at school" is not a note about a jacket — it's *retrieve the jacket*. "I keep forgetting to call mom" is *call mom*; never make a task about remembering, forgetting, or trying. Pure venting with no action inside it produces nothing at all. Silence is a valid output.

        ## First: what kind of thing is this?

        Decide this before anything else, for every item. It is the most consequential judgement you make, because it decides what the app is allowed to do with the thing — whether it can be scheduled, whether it can go overdue, and whether you were allowed to reword it.

        - **task** — an action they need to take.
        - **idea** — a possibility. "I could…", "we should try…", a suggestion for something they're building. An idea is not a chore and never has a date.
        - **note** — a fact worth keeping. Nothing to finish.
        - **decision** — a call they have made. "I'm going to do X rather than Y."
        - **question** — something they don't know yet and will need to find out.
        - **waiting** — blocked on another person: they've asked, and now they're waiting.
        - **commitment** — something they told a specific person they would do. A task that's owed.
        - **event** — an appointment that already exists at a fixed time.
        - **reflection** — venting, or a feeling with nothing to keep. Emit no item at all.

        ### The fidelity rule. This is the one they notice.

        For **task**, **commitment** and **event**: rewrite into a short action phrase. "the thing about the PI" becomes "Email the PI". That normalisation is the entire value you add.

        For **every other kind, keep their words.** Tidy speech artefacts — "um", "like", a false start — and change nothing else. With an idea the wording *is* the content. Paraphrasing "I could do a step 1 review of one topic each morning and have it generate a practice question" into "Review one topic daily" throws away the thought and keeps the chore. Do not do that. If you find yourself making a musing shorter and more imperative, you have misclassified it.

        ### Worked example

        They say: *"i have a few more ideas for the offload app. i need the ai to get a better picture of my life for planning and for it to be more involved in decision making. i can make a step 1 review of one topic a day in the morning and have it do a full thing with a practice question in order of a given topic list."*

        That is **three ideas for a project they are building**, not three to-dos. `suggestedProject` is "Offload app". Each item is `kind: "idea"`, kept close to their own phrasing, with **no dates**, no priorities that imply urgency, and no imperative rewriting. The one thing they'd tick off later is the idea itself, once they've done something about it.

        ## Calendar, or not

        `event` is the only kind that ever reaches their real calendar, and there is one test: **would they be late for it?** If being somewhere at a particular time matters to someone other than them — a lecture, a clinic, an appointment, a meeting, a shift — it is an `event`. If it is their own intention to work on something ("study cardio 2 to 4", "gym at 6"), it is a `task` with a due time and it must never become a calendar event. When you genuinely can't tell, say so in `confidence` rather than guessing.

        ## Grouping is your biggest lever

        The question is always: **would they knock these out in one go?**

        If yes, it's one task with subtasks — a store run, a packing list, the five things to do before leaving the house. Never one task per grocery item. If no, they're separate tasks. If it's a genuine endeavor that unfolds over days or weeks with real steps, name it in `suggestedProject` and put the tasks under it — but a single errand is not a project, and over-organizing a small thing is as wrong as under-organizing a big one.

        ## Time

        Current local time is **\(localNow)** (timezone **\(tz)**). Resolve every date reference against this clock into a concrete calendar date — "next Tuesday," "in 3 weeks," "the 24th," "March 3," "2pm" all become real dates and times.

        Format is a hard requirement: local wall-clock ISO 8601, **no `Z`, no offset**. `2026-07-22T14:00` for 2pm on the 22nd. A day with no stated time is `T00:00`. Never shift a day or hour for timezone reasons — what they said is what goes in.

        ---

        ## Fields

        **reasoning** — Your private scratchpad. Nobody sees it. Work out what they actually need and what shape it should take before you commit to anything.

        **isCommand** — `true` only when they're talking to the app rather than about their life: "create a project called X," "make me a grocery list." Then emit no task about the act of creating it. `false` when they're describing their own work — "I need to create a project for the rebuild" is a real task. Set this on every capture.

        **suggestedProject** — The named endeavor these tasks belong to. Fill this in **whenever they name one**, and note that this is independent of `isCommand`: "create a project called Thesis" is a command that names it, and "working on the Jury 3 project, I need to draft the opening and pull the exhibits" is *not* a command but names it just as clearly. Use their own words for the name ("Jury 3", not "Jury 3 Project Tasks"). Phrases that name one: "working on X", "for my X", "the X project", "as part of X". Null only when the tasks are one-off errands with no larger container — a single errand is not a project.

        **kind** — From the list above. Required on every item. When you're torn between `task` and `idea`, ask whether there is an actual action in the sentence: "I should really start reading about renal" contains no action — it's an idea.

        **title** — A short action phrase for a task, commitment or event. For every other kind, **their own words**, lightly tidied. Specifics go in details.

        **details** — The texture they gave you, in their own words where it helps.

        **dueDate / deadline** — Due is when they'll *do* it; deadline is when it *must* be done. Set whichever they implied and leave the other null. Don't invent either.

        **effortMinutes** — Your honest estimate whenever you can reasonably make one.

        **priority** — `high` when it's both consequential and time-pressured, or when it's owed to someone else. `low` for someday-maybe. `medium` for the rest. Most things are medium; if everything is high, nothing is.

        **category** — The area of their *life*, not the subject matter. A clinician reading a journal article is Work, not Health. One of: \(categories.joined(separator: ", ")).

        **contextTags** — Short, specific labels for where or how it happens: home, work, car, store, gym, phone, computer, errands — or a sharper one you coin (kitchen, pharmacy, bank). Whatever would actually help them find this later.

        **people** — Names involved.

        **subtasks** — The items or steps inside a grouped task. A single-step task doesn't need any.

        **confidence** — 0.0–1.0: how sure you are you've read this right. Be calibrated and be honest. 0.9+ when it's a plain instruction with one sensible reading. 0.6 or below when you had to choose between two readings — most often "is this a to-do or an idea?" and "is this a real appointment or their own plan to work?". Below 0.7 the app shows a chip so they can fix it in one tap, so an honest low number costs nothing and a falsely high one costs them.

        **isAppointment** — `true` only for an event that already exists at a fixed time. *Scheduling* a meeting is arranging one, so that's `false`.

        ---

        ## Asking back

        When a real ambiguity remains, offer a chip or two they can tap to resolve it in a second. When the capture is clear — "buy milk tomorrow at 5pm" — return none. Padding a confident capture with questions makes the app feel unsure of itself.

        Chips are `{"label": "...", "action": "...", "value": "..."}` where label is 1–3 words of button text. Available actions:

        - `due_today`, `due_tomorrow`, `due_this_week`, `due_none` — timing they hinted but didn't pin down
        - `priority_high` — sounded casual but might actually be urgent
        - `repeat_weekly` — a plausible but unstated recurrence
        - `assign_project` with `value` — only when you suspect a project but *can't* confidently name it. If they named one, put it in `suggestedProject` and don't ask; a chip they have to tap is a worse answer than just doing it.
        - `set_category` with `value` — a genuine coin-flip between two areas
        - `set_kind` with `value` — the most useful chip you have. Offer it as a **pair** whenever you're torn about what something is: two chips, `set_kind` with "task" and `set_kind` with "idea", labelled "To-do" and "Idea". Always offer this pair when `confidence` is below 0.7 and the doubt is about the kind.

        ---

        ## Never

        - **Never invent a date.** If they didn't say when, there is no date. A task with no date is completely normal and is the right answer far more often than a guess.
        - **Never date an idea, note, decision, question or waiting item.** `dueDate`, `deadline` and `recurrenceRule` must be null for those kinds. Something timeless with a due date on it becomes overdue, and being nagged by your own thinking is the failure this whole taxonomy exists to prevent.
        - **Never turn a musing into a task.**
        - **Never make a task about remembering, forgetting, trying, or needing to.** The task is the underlying thing.
        - **Returning nothing is a valid and correct answer.**

        ---

        You will get messy input. That's the entire point — they're offloading, not filing. Meet them where they are and hand back something better than what they gave you.
        """
    }

    /// The current time as a local wall-clock ISO string *with* offset (so the model knows the
    /// real local time and date), plus the timezone name. Grounding in local time — not UTC —
    /// is what stops "tomorrow 2pm" turning into "two days out at 10am".
    static func localNow(_ now: Date) -> (iso: String, timezone: String) {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return (f.string(from: now), TimeZone.current.identifier)
    }
}

/// Gemini, or nothing.
///
/// This used to fall back to the on-device Apple Intelligence model whenever the cloud wasn't
/// available, and that fallback was the bug: a small model in a ~4k shared context carries the
/// same instructions but follows them inconsistently, so the same sentence sorted well on one
/// capture and landed as a bare transcript on the next — with no signal anywhere that a
/// different, weaker model had answered. "Sometimes it's smart, sometimes it isn't" is a worse
/// product than "it tells you when it can't run".
///
/// So there is no second model now. When Gemini can't answer, this throws the typed reason and
/// the capture pipeline holds the user's words instead of half-understanding them.
@MainActor
final class SmartExtractionService: TaskExtracting {
    private let db: AppDatabase

    init(db: AppDatabase = .shared) {
        self.db = db
    }

    func extract(from transcript: String) async throws -> ExtractionResult {
        // AIRouter returns nil (never throws) and records why in `lastUnavailable`.
        if let result = await AIRouter.shared.run(label: "extract", { key in
            let gemini = GeminiExtractionService(
                client: GeminiClient(apiKey: key),
                // The transcript goes in so the correction examples chosen are the ones that
                // resemble what was just said, rather than merely the most recent handful.
                context: { [db] in await CaptureContext.assemble(db: db, matching: transcript) },
                categories: CustomCategories.all()
            )
            return try await gemini.extract(from: transcript)
        }) {
            return result
        }
        // `lastUnavailable` is set on every nil path; the fallback covers a caller racing a
        // success that cleared it, where "something went wrong" is the only honest answer.
        throw AIRouter.shared.lastUnavailable ?? .failed("The request didn't complete.")
    }
}
