import FoundationModels

/// Typed output for core extraction (spec §3.2). The compiler generates the schema from
/// `@Generable`; `@Guide` adds field constraints. With constrained decoding the model
/// cannot emit a structurally invalid result — we get typed Swift values, not JSON to parse.
@Generable
struct ExtractedCapture {
    @Guide(description: "One short line capturing the user's overall intent, or nil if none")
    var summary: String?

    var tasks: [ExtractedTask]

    @Guide(description: "A project name if these tasks form one multi-step endeavor, else nil")
    var suggestedProject: String?
}

@Generable
struct ExtractedTask {
    @Guide(description: "Concise, actionable title, 2–6 words")
    var title: String

    @Guide(.anyOf(["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]))
    var category: String

    @Guide(.anyOf(["high", "medium", "low"]))
    var priority: String

    @Guide(description: "Context tags, each chosen only from: home, work, car, outside, store, gym, phone, computer, meeting, errands")
    var contextTags: [String]

    @Guide(description: "ISO 8601 datetime if the user implied timing, else nil")
    var dueDate: String?

    @Guide(description: "Recurrence as an iCalendar RRULE if implied (e.g. weekly), else nil")
    var recurrenceRule: String?

    @Guide(description: "Estimated effort in minutes if inferable, else nil")
    var effortMinutes: Int?
}
