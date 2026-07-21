import FoundationModels

/// Typed output for core extraction (spec §3.2). The compiler generates the schema from
/// `@Generable`; `@Guide` adds field constraints. With constrained decoding the model
/// cannot emit a structurally invalid result — we get typed Swift values, not JSON to parse.
/// Terse `@Guide` text on purpose: every description is injected into the model's context
/// alongside the system prompt, so the schema competes with the instructions for the same
/// small window. The rules live in the prompt; these just label the fields.
@Generable
struct ExtractedCapture {
    @Guide(description: "One-line summary of intent, or nil")
    var summary: String?

    var tasks: [ExtractedTask]

    @Guide(description: "Project name if these tasks form one multi-step endeavour, else nil")
    var suggestedProject: String?
}

@Generable
struct ExtractedTask {
    @Guide(description: "Short action title, 2–6 words")
    var title: String

    @Guide(description: "Specifics from the user's own words (names, numbers, context), or nil")
    var details: String?

    @Guide(.anyOf(["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]))
    var category: String

    @Guide(.anyOf(["high", "medium", "low"]))
    var priority: String

    @Guide(description: "From: home, work, car, outside, store, gym, phone, computer, meeting, errands")
    var contextTags: [String]

    @Guide(description: "People the task involves, named exactly as said, else empty")
    var people: [String] = []

    @Guide(description: "When they'll do it, ISO 8601; time only if stated, else date at 00:00; nil if no time mentioned")
    var dueDate: String?

    @Guide(description: "Hard deadline if stated (ISO 8601), else nil")
    var deadline: String?

    @Guide(description: "iCalendar RRULE if a repeat is implied, else nil")
    var recurrenceRule: String?

    @Guide(description: "Effort in minutes if the user implied a duration, else nil")
    var effortMinutes: Int?

    @Guide(description: "true only for an existing appointment with a stated time; false for to-dos")
    var isAppointment: Bool = false

    @Guide(description: "Sub-step titles only if the task has 2+ distinct actions, else empty")
    var subtasks: [String]
}
