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

    /// Deliberately permissive: the old wording ("if these tasks form one multi-step endeavour")
    /// asked the model to make a judgement about the *shape* of the work, which a small on-device
    /// model almost never answered yes to — so a capture that plainly said "the Jury 3 project"
    /// produced no project at all. Naming something the user named is a much easier question than
    /// classifying an endeavour, and a wrong guess is cheap now: an unapplied name becomes a
    /// "file this under X?" offer on the success screen rather than a silently created project.
    @Guide(description: "A project/list the user named or referred to (\"the Jury 3 project\", \"for my thesis\"), else nil")
    var suggestedProject: String?

    /// How sure the model is that it read the capture right, 0…1.
    ///
    /// Used for one thing only: below a threshold the result screen offers a single clarifying
    /// chip row instead of presenting a guess as a fact. An assistant that occasionally asks one
    /// sharp question reads as smarter than one that is confidently wrong, and before this the app
    /// had no way to be anything but confident.
    @Guide(description: "0.0–1.0 confidence that this reading is right")
    var confidence: Double?
}

@Generable
struct ExtractedTask {
    /// What kind of thing this is — see `CaptureKind`. The field that decides whether this may be
    /// scheduled at all, and whether the model was allowed to reword it.
    @Guide(.anyOf(["task", "idea", "note", "decision", "question", "waiting", "commitment", "event", "reflection"]))
    var kind: String = "task"

    @Guide(description: "Action title for a task (2–6 words); the user's own wording for anything else")
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

// Both are plain value types; making Sendable explicit lets a cloud-extracted result cross
// safely from the (nonisolated) network layer back to the main actor.
extension ExtractedCapture: @unchecked Sendable {}
extension ExtractedTask: @unchecked Sendable {}
