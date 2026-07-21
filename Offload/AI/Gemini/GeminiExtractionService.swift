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
        var tasks: [GTask]
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

        return .object(properties: [
            .init("summary", .string(nullable: true)),
            .init("suggestedProject", .string(nullable: true)),
            .init("tasks", .array(task))
        ], required: ["tasks"])
    }

    func extract(from transcript: String, now: Date = Date()) async throws -> ExtractedCapture {
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
        return Self.domain(capture)
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

    /// The instructions. This model has room to spare, so it can be fuller than the on-device
    /// prompt — but the deterministic guards still enforce the hard rules regardless.
    static func systemPrompt(now: Date, categories: [String]) -> String {
        let nowStr = ISO8601DateFormatter().string(from: now)
        return """
        You convert a person's quick voice or text capture into the tasks they actually mean.
        The current date/time is \(nowStr); use it only to resolve time words they actually said.

        Principles:
        - Capture only what they said. Never invent tasks, steps, dates, or effort. If they name
          three things, produce three tasks — never a generic research/design/build/launch plan.
        - Extract the ACTION, not the words: "left my jacket at school" → "Retrieve jacket from
          school"; "keep forgetting to call mom" → "Call mom". Never a task about
          remembering/forgetting/trying. Pure venting with no action → no task at all.
        - A command TO the app makes a container, not a task: "create a project called X" → set
          suggestedProject to X, no task about creating it. But "I need to create a project" is
          the user's own work → a task.
        - dueDate: null unless they said when. A day with no stated time is that date at 00:00
          (all-day). Never pick an hour between 10pm–7am unless they named a night-time hour.
          deadline (when it MUST be done) is separate from dueDate (when they'll do it).
        - priority high only if important AND time-sensitive or high-consequence (bills, health,
          owed to someone); low for someday/maybe; else medium.
        - category = the area of their LIFE, not the subject (a clinician reviewing scans is doing
          Work, not Health). Choose one of: \(categories.joined(separator: ", ")).
        - contextTags only from: home, work, car, outside, store, gym, phone, computer, meeting,
          errands. people = names the task involves, exactly as said, else empty.
        - subtasks only when a task genuinely has 2+ distinct steps. isAppointment true only for
          an event that already exists AND has a stated time ("schedule a meeting" = arranging
          one → false).
        Keep titles short action phrases; put specifics in details, using only their own words.
        """
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

    func extract(from transcript: String) async throws -> ExtractedCapture {
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
