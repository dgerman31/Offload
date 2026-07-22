import Foundation

/// Extraction via Gemini. Produces the same `ExtractedCapture` the on-device path does, so
/// everything downstream — `CaptureMapper` and its deterministic guards — is unchanged. A far
/// larger model with a huge context window means the failures that plagued the small on-device
/// model (invented tasks, dropped context, the 4k-token overflow) simply don't happen here.
@MainActor
struct GeminiExtractionService {

    var client: GeminiClient
    var personalization: () async -> String?
    var categories: [String]

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
    }
    private struct GTask: Codable {
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
        ], required: ["title", "category", "priority", "contextTags", "people", "isAppointment", "subtasks"])

        let chip: GSchema = .object(properties: [
            .init("label", .string()),
            .init("action", .string(enumValues: [
                "due_today", "due_tomorrow", "due_this_week", "due_none",
                "priority_high", "repeat_weekly", "set_category", "assign_project"
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
            .init("chips", .array(chip))
        ], required: ["tasks", "isCommand"])
    }

    func extract(from transcript: String, now: Date = Date()) async throws -> ExtractionResult {
        var system = Self.systemPrompt(now: now, categories: categories)
        if let learned = await personalization() {
            system += "\n\nThis user's past corrections (follow them):\n" + learned
        }

        let capture = try await client.generate(
            system: system,
            prompt: transcript,
            schema: Self.schema(categories: categories),
            as: GCapture.self,
            temperature: 0.2
        )
        return ExtractionResult(
            capture: Self.domain(capture),
            chips: Self.chips(capture.chips),
            isProjectCommand: capture.isCommand
        )
    }

    /// Map the wire DTO to the domain type the rest of the app already understands.
    private static func domain(_ g: GCapture) -> ExtractedCapture {
        ExtractedCapture(
            summary: g.summary,
            tasks: g.tasks.map { t in
                ExtractedTask(
                    title: t.title, details: t.details, category: t.category, priority: t.priority,
                    contextTags: t.contextTags, people: t.people, dueDate: t.dueDate,
                    deadline: t.deadline, recurrenceRule: t.recurrenceRule, effortMinutes: t.effortMinutes,
                    isAppointment: t.isAppointment, subtasks: t.subtasks
                )
            },
            suggestedProject: g.suggestedProject
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

        ## Grouping is your biggest lever

        The question is always: **would they knock these out in one go?**

        If yes, it's one task with subtasks — a store run, a packing list, the five things to do before leaving the house. Never one task per grocery item. If no, they're separate tasks. If it's a genuine endeavor that unfolds over days or weeks with real steps, name a project and put the tasks under it — but a single errand is not a project, and over-organizing a small thing is as wrong as under-organizing a big one.

        ## Time

        Current local time is **\(localNow)** (timezone **\(tz)**). Resolve every date reference against this clock into a concrete calendar date — "next Tuesday," "in 3 weeks," "the 24th," "March 3," "2pm" all become real dates and times.

        Format is a hard requirement: local wall-clock ISO 8601, **no `Z`, no offset**. `2026-07-22T14:00` for 2pm on the 22nd. A day with no stated time is `T00:00`. Never shift a day or hour for timezone reasons — what they said is what goes in.

        ---

        ## Fields

        **reasoning** — Your private scratchpad. Nobody sees it. Work out what they actually need and what shape it should take before you commit to anything.

        **isCommand** — `true` only when they're talking to the app rather than about their life: "create a project called X," "make me a grocery list." Then set `suggestedProject` and emit no task about the act of creating it. `false` when they're describing their own work — "I need to create a project for the rebuild" is a real task. Set this on every capture.

        **title** — A short action phrase. Specifics go in details.

        **details** — The texture they gave you, in their own words where it helps.

        **dueDate / deadline** — Due is when they'll *do* it; deadline is when it *must* be done. Set whichever they implied and leave the other null. Don't invent either.

        **effortMinutes** — Your honest estimate whenever you can reasonably make one.

        **priority** — `high` when it's both consequential and time-pressured, or when it's owed to someone else. `low` for someday-maybe. `medium` for the rest. Most things are medium; if everything is high, nothing is.

        **category** — The area of their *life*, not the subject matter. A clinician reading a journal article is Work, not Health. One of: \(categories.joined(separator: ", ")).

        **contextTags** — Short, specific labels for where or how it happens: home, work, car, store, gym, phone, computer, errands — or a sharper one you coin (kitchen, pharmacy, bank). Whatever would actually help them find this later.

        **people** — Names involved.

        **subtasks** — The items or steps inside a grouped task. A single-step task doesn't need any.

        **isAppointment** — `true` only for an event that already exists at a fixed time. *Scheduling* a meeting is arranging one, so that's `false`.

        ---

        ## Asking back

        When a real ambiguity remains, offer a chip or two they can tap to resolve it in a second. When the capture is clear — "buy milk tomorrow at 5pm" — return none. Padding a confident capture with questions makes the app feel unsure of itself.

        Chips are `{"label": "...", "action": "...", "value": "..."}` where label is 1–3 words of button text. Available actions:

        - `due_today`, `due_tomorrow`, `due_this_week`, `due_none` — timing they hinted but didn't pin down
        - `priority_high` — sounded casual but might actually be urgent
        - `repeat_weekly` — a plausible but unstated recurrence
        - `assign_project` with `value` — it clearly belongs to a project you can name
        - `set_category` with `value` — a genuine coin-flip between two areas

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

/// Prefers Gemini, falls back to on-device Apple Intelligence only when there's no key, no
/// network, no budget, or the call fails. Conforms to the same `TaskExtracting` protocol the
/// capture pipeline already depends on, so nothing above it changes.
@MainActor
final class SmartExtractionService: TaskExtracting {
    private let db: AppDatabase
    private let onDevice: ExtractionService

    init(db: AppDatabase = .shared) {
        self.db = db
        self.onDevice = ExtractionService(db: db)
    }

    func extract(from transcript: String) async throws -> ExtractionResult {
        // AIRouter returns nil (never throws) when the cloud isn't available or the call fails,
        // so a simple `if let` cleanly expresses "Gemini, else fall back".
        if let result = await AIRouter.shared.run(label: "extract", { key in
            let gemini = GeminiExtractionService(
                client: GeminiClient(apiKey: key),
                personalization: { [db] in await Personalization.fragment(db: db) },
                categories: CustomCategories.all()
            )
            return try await gemini.extract(from: transcript)
        }) {
            return result
        }
        // No cloud (no key / offline / over budget / error) → the on-device model.
        return try await onDevice.extract(from: transcript)
    }
}
