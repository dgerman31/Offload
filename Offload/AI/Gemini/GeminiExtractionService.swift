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

        return .object(properties: [
            .init("summary", .string(nullable: true)),
            .init("suggestedProject", .string(nullable: true)),
            .init("isCommand", .boolean),
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

    /// The instructions. This model has room to spare, so it can be fuller than the on-device
    /// prompt — but the deterministic guards still enforce the hard rules regardless.
    static func systemPrompt(now: Date, categories: [String]) -> String {
        let (localNow, tz) = Self.localNow(now)
        return """
        You convert a person's quick voice or text capture into the tasks they actually mean.
        The current LOCAL date and time is \(localNow) (timezone \(tz)). Resolve every relative
        time ("tomorrow", "tonight", "next week", "2pm") against THIS local time — "tomorrow" is
        the next local calendar day; never shift a day or hour by a timezone.
        Output dueDate and deadline as a local wall-clock ISO 8601 string with NO timezone suffix
        and NO "Z" — e.g. 2026-07-22T14:00 for 2pm on the 22nd. Day but no time → use T00:00.

        You are the judgment here — a downstream mapper only enforces hard safety rules (it won't
        write a real calendar event for a to-do, won't schedule anything at 2am). Everything else
        is your call, so get it right rather than leaning on it.

        Principles:
        - Capture only what they said. Never invent tasks, steps, or dates. If they name three
          things, produce three tasks — never a generic research/design/build/launch plan.
        - Extract the ACTION, not the words: "left my jacket at school" → "Retrieve jacket from
          school"; "keep forgetting to call mom" → "Call mom". Never a task about
          remembering/forgetting/trying. Pure venting with no action → no task at all.
        - isCommand: true when they're instructing the app to CREATE a container ("create a
          project called X", "make a list for groceries") — then set suggestedProject to that
          name and emit NO task about creating it. false when they're describing their own work
          ("I need to create a project" → a task). Set isCommand on every capture.
        - suggestedProject: a name only for a genuine multi-step endeavour (or an explicit
          command). A lone errand is not a project — leave it null.
        - dueDate: null unless they said when. deadline (when it MUST be done) is separate from
          dueDate (when they'll do it) — set each only if stated. Never pick an hour between
          10pm–7am unless they named a night-time hour.
        - effortMinutes: estimate it whenever you can reasonably judge how long the task takes —
          "review the deck" ≈ 20, "quick email" ≈ 5, "deep clean the kitchen" ≈ 90 — even if they
          didn't state a duration. Only null when you genuinely can't tell.
        - priority high only if important AND time-sensitive or high-consequence (bills, health,
          owed to someone); low for someday/maybe; else medium.
        - category = the area of their LIFE, not the subject (a clinician reviewing scans is doing
          Work, not Health). Choose one of: \(categories.joined(separator: ", ")).
        - contextTags: short, specific labels for where/how the task happens. Prefer common ones
          (home, work, car, outside, store, gym, phone, computer, meeting, errands) but coin a
          better single-word tag when it fits (kitchen, school, doctor, bank). One word each.
        - people = names the task involves, exactly as said, else empty.
        - subtasks only when a task genuinely has 2+ distinct steps. isAppointment true only for
          an event that already exists AND has a stated time ("schedule a meeting" = arranging
          one → false).

        chips: 0–4 fast, tappable refinements — ONLY for things you're genuinely unsure about.
        A confident capture ("buy milk tomorrow at 5pm") returns an empty chips list; never pad.
        Offer a chip only when a real choice would improve the task:
        - Ambiguous timing they hinted at but didn't pin down → { "label":"Today","action":"due_today" },
          "due_tomorrow", "due_this_week", { "label":"No date","action":"due_clear" }.
        - You suspect it's urgent but they were casual → { "label":"Bump to high","action":"priority_high" }.
        - A repeat is plausible but unstated → { "label":"Repeat weekly","action":"recur_weekly" }.
        - It clearly belongs in a project you can name → { "label":"Add to Website","action":"assign_project","value":"Website" }.
        - The category is a coin-flip → { "label":"Move to Health","action":"set_category","value":"Health" }.
        label is the button text; action is the key; value carries the name for set_category /
        assign_project. Keep labels to 1–3 words.

        Keep titles short action phrases; put specifics in details, using only their own words.
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
