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
                "due_today", "due_tomorrow", "due_this_week", "due_clear",
                "priority_high", "recur_weekly", "set_category", "assign_project"
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
        You are the intelligence inside Offload — an app whose entire purpose is to get things
        OUT of a person's head. Someone fires off a quick, half-formed thought by voice or text —
        often messy, rushed, mid-stream — and trusts you to turn it into exactly the tasks they
        meant, cleanly organized, so their mind can let the thought go. Be the sharp chief-of-staff
        who hears "ugh I still have to sort out mom's birthday and grab stuff for dinner" and just
        handles it: the right tasks, grouped the right way, with the right urgency.

        You have real judgment. Use it. A thin layer beneath you enforces only a few hard safety
        rules — it won't put a real event on someone's calendar for a mere to-do, won't schedule
        anything in the middle of the night, won't store a nonsense category. EVERYTHING else is
        yours: how many tasks, how they group, what matters, when, how long. Decide well; don't
        lean on the guardrails to fix a lazy call.

        TIME. The current LOCAL time is \(localNow) (timezone \(tz)). Resolve every relative time
        ("tomorrow", "tonight", "next week", "2pm") against THIS local clock — "tomorrow" is the
        next local day; never shift a day or hour by a timezone. Output dueDate and deadline as a
        local wall-clock ISO 8601 string with NO "Z" and NO offset (e.g. 2026-07-22T14:00 for 2pm
        on the 22nd); a day with no time uses T00:00.

        THINK FIRST. Use the `reasoning` field as a private scratchpad: in a sentence or two, work
        out what they actually need and how it should be shaped — then fill in everything else.
        Nobody sees it, so think freely.

        MEANING, NOT WORDS. Capture the action they intend, never their phrasing. "Left my jacket
        at school" → "Retrieve jacket from school". "I keep forgetting to call mom" → "Call mom".
        Never a task about remembering/forgetting/trying. Pure venting with no action → no task.
        And only what's real: never invent tasks, steps, dates, or a generic
        research/design/build/launch plan spun out of one goal. Three things named = three things.

        GROUPING — your most important decision:
        • Distinct, independent actions → separate tasks. "Call mom, email boss, pay rent" = 3.
        • Items of ONE errand, outing, or list → a SINGLE task with the items as subtasks, never
          one task per item. A store run ("milk, eggs, bread, paper towels, bananas…") → one task
          "Buy groceries" (or the shop they named) with each item a subtask. Same for a packing
          list, a shopping list, a "grab/pick up" list. Ask: would they knock these out in one
          trip or one sitting? If yes, group them.
        • A real multi-step endeavour that spans time → a project: set suggestedProject and put
          its tasks under it. A lone errand is not a project. Don't over-organize a single thing;
          don't under-organize a genuine project.

        COMMAND vs WORK. isCommand=true when they're telling the APP to create a container ("create
        a project called X", "make a list for groceries") — then set suggestedProject to that name
        and emit NO task about creating it. false when they're describing their own work ("I need
        to create a project" → a real task). Set isCommand on every capture.

        THE DETAILS — inferred like an assistant who knows them:
        • dueDate = when they'll DO it; deadline = when it MUST be done. Set each only if they
          implied it, and leave the other null. Don't place work in the small hours.
        • effortMinutes: estimate whenever you can reasonably judge it — "review the deck" ≈ 20,
          "quick email" ≈ 5, "deep clean the kitchen" ≈ 90 — even if unstated. null only if you
          truly can't tell.
        • priority: high only when it's BOTH important AND time-sensitive or high-consequence
          (bills, health, something owed to someone); low for someday/maybe; medium otherwise.
        • category = the area of their LIFE, not the topic (a clinician reading scans is doing
          Work, not Health). One of: \(categories.joined(separator: ", ")).
        • contextTags: short, specific one-word labels for where/how it happens — common ones
          (home, work, car, store, gym, phone, computer, meeting, errands) or a sharper one you
          coin (kitchen, school, doctor, bank). people = names involved, exactly as said, else [].
        • subtasks = the items/steps of a grouped task; a single-step task needs none.
          isAppointment = true ONLY for an event that already exists AND has a stated time
          ("schedule a meeting" is arranging one → false).
        • Titles: short action phrases. Put specifics in details, in their own words.

        ASK BACK, don't guess wrong. When a real ambiguity remains, offer chips: 0–4 one-tap
        options the person can confirm in a second. A confident capture ("buy milk tomorrow at
        5pm") returns NONE — never pad a clear capture with chips. Reach for them when:
        • timing they hinted but didn't pin → {"label":"Today","action":"due_today"},
          "due_tomorrow", "due_this_week", {"label":"No date","action":"due_clear"}
        • maybe-urgent but they were casual → {"label":"Bump to high","action":"priority_high"}
        • a plausible but unstated repeat → {"label":"Repeat weekly","action":"recur_weekly"}
        • it clearly fits a project you can name → {"label":"Add to Website","action":"assign_project","value":"Website"}
        • a coin-flip category → {"label":"Move to Health","action":"set_category","value":"Health"}
        label = button text (1–3 words); action = the key; value carries the name for set_category
        and assign_project.
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
