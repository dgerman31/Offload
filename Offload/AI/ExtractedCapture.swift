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

    @Guide(description: "The specifics that don't belong in the short title — names, numbers, constraints, context worth keeping from what the user said. Use ONLY their own information, never invented advice or steps. nil when the title already says everything.")
    var details: String?

    @Guide(.anyOf(["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]))
    var category: String

    @Guide(.anyOf(["high", "medium", "low"]))
    var priority: String

    @Guide(description: "Context tags, each chosen only from: home, work, car, outside, store, gym, phone, computer, meeting, errands")
    var contextTags: [String]

    @Guide(description: "Names of people this task actually involves — someone you owe something to, are meeting, or must contact. Use the name exactly as the user said it (\"Sarah\", \"Dr. Patel\", \"mom\"). Empty when no specific person is named; never invent one.")
    var people: [String] = []

    @Guide(description: "When the user said they'd DO this, ISO 8601. Include a time ONLY if they stated one (\"3pm\"); otherwise give just the date at 00:00. nil unless they actually mentioned when — never guess from the current time.")
    var dueDate: String?

    @Guide(description: "A hard deadline if the user stated one (\"due Friday\", \"before the 5th\"), ISO 8601. This is when it MUST be finished, which is often different from when they'll do it. nil if no deadline was stated.")
    var deadline: String?

    @Guide(description: "Recurrence as an iCalendar RRULE if implied (e.g. weekly), else nil")
    var recurrenceRule: String?

    @Guide(description: "Estimated effort in minutes if inferable, else nil")
    var effortMinutes: Int?

    @Guide(description: "true ONLY for a real calendar appointment at a specific time — a meeting, doctor visit, reservation, or a call scheduled for a set time. false for to-dos, errands, and reminders, even if they have a due date.")
    var isAppointment: Bool = false

    @Guide(description: "Sub-step titles ONLY when this task genuinely contains 2+ distinct actions; each must be its own concrete step, never a restatement of the task itself. A single errand (\"buy milk\", \"go to the store to buy milk\") has NO subtasks — leave empty.")
    var subtasks: [String]
}
