import Foundation

/// What kind of thing a capture actually is.
///
/// ### Why this exists
///
/// The app used to have exactly one output shape. Extraction produced tasks, so *everything* you
/// said became a thing to check off — because a task was the only container there was. Say "I have
/// a few ideas for the app: I could review one topic a day, have it generate a practice question,
/// work through a topic list" and you'd get three imperative to-dos, paraphrased into chores. The
/// model wasn't misunderstanding you. It was translating, because it had nowhere else to put them.
///
/// So an idea is now a different kind of thing from a task, and the difference is enforced all the
/// way down: what it's allowed to do, how it's rendered, and — crucially — whether the model may
/// reword it.
///
/// ### The rule that matters most
///
/// **Tasks should be rewritten. Everything else should not.** "the thing about the PI" is a worse
/// task than "email the PI" — normalising it into an imperative is the whole value. But with an
/// idea, the wording *is* the content: paraphrasing "I could do a step-1 review of one topic each
/// morning" into "Review one topic daily" throws away the thought and keeps the chore. See
/// `keepsWording`.
enum CaptureKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Something to do. The only kind the app rewrites into imperative form.
    case task
    /// A possibility for a project. Checkable — you can act on one — but never scheduled, never
    /// due, never overdue. Ideas don't nag.
    case idea
    /// A fact worth keeping. Not something you finish.
    case note
    /// A call you made, kept with its date so "why did we do it this way" is answerable later.
    case decision
    /// Something you don't know yet. Closes when it has an answer.
    case question
    /// Blocked on someone else. Open, but not yours to act on — so it ages rather than nags.
    case waiting
    /// Something you told a person you'd do. A task that's owed, which is why it's separate.
    case commitment
    /// A real appointment at a real time. The kind — and the only kind — that reaches the calendar.
    case event
    /// Venting, or a passing feeling. Produces no row at all; the words stay in the journal.
    case reflection

    var id: String { rawValue }

    /// May carry a due date, be planned into a day, and go overdue.
    ///
    /// Everything else is deliberately timeless. An idea with a due date is a chore wearing a
    /// different hat, and it's exactly what made captured thinking feel like captured work.
    var isSchedulable: Bool {
        switch self {
        case .task, .commitment, .event: return true
        case .idea, .note, .decision, .question, .waiting, .reflection: return false
        }
    }

    /// Has a done state.
    ///
    /// Ideas and questions are checkable on purpose — you asked for that, and it's right: acting on
    /// an idea or answering a question is a real event worth recording. What they are *not* is
    /// schedulable, which is the part that made them feel like chores.
    var isCheckable: Bool {
        switch self {
        case .task, .commitment, .idea, .question, .waiting: return true
        case .note, .decision, .event, .reflection: return false
        }
    }

    /// The model must keep the user's own phrasing, only tidying obvious speech artefacts.
    ///
    /// True for everything that isn't an action. See the type's note — this is the single rule that
    /// fixes "it paraphrased my ideas into short actionable things".
    var keepsWording: Bool {
        switch self {
        case .task, .commitment, .event: return false
        case .idea, .note, .decision, .question, .waiting, .reflection: return true
        }
    }

    /// Whether this is something you're still *carrying* — the thing `MentalLoad` counts.
    ///
    /// Distinct from `isCheckable`, and the difference matters: an idea can be ticked off, but
    /// having written it down means you've stopped holding it, which is the entire promise of the
    /// app. Counting ideas as open loops would make the headline number go *up* every time
    /// offloading worked. What genuinely stays on your mind is work you owe, a question you
    /// haven't answered, and someone you're waiting on.
    var countsAsOpenLoop: Bool {
        switch self {
        case .task, .commitment, .event, .waiting, .question: return true
        case .idea, .note, .decision, .reflection:            return false
        }
    }

    /// Nothing is stored for a reflection — the capture row already holds the words.
    var isStored: Bool { self != .reflection }

    /// Singular, sentence case, as it would appear on a chip.
    var label: String {
        switch self {
        case .task:       return "To do"
        case .idea:       return "Idea"
        case .note:       return "Note"
        case .decision:   return "Decision"
        case .question:   return "Question"
        case .waiting:    return "Waiting on"
        case .commitment: return "Promised"
        case .event:      return "Appointment"
        case .reflection: return "Just thinking"
        }
    }

    /// The kind with its article, for use inside a sentence — "is **an idea**, not **a to-do**".
    ///
    /// Separate from `label` because a chip wants a noun and a sentence wants a noun phrase, and
    /// the one place this matters most is the correction fragment the model reads: "is an idea, not
    /// a to-do" is a fact about the sentence, where "kind: idea" is a fact about a database column,
    /// and only one of those generalises to the next capture.
    var phrase: String {
        switch self {
        case .task:       return "a to-do"
        case .idea:       return "an idea"
        case .note:       return "a note"
        case .decision:   return "a decision they made"
        case .question:   return "an open question"
        case .waiting:    return "something they're waiting on someone for"
        case .commitment: return "something they promised someone"
        case .event:      return "an appointment"
        case .reflection: return "just thinking out loud"
        }
    }

    /// The heading this kind gathers under inside a project.
    var sectionTitle: String {
        switch self {
        case .task, .commitment: return "Next actions"
        case .idea:              return "Ideas"
        case .note:              return "Notes"
        case .decision:          return "Decisions"
        case .question:          return "Open questions"
        case .waiting:           return "Waiting on"
        case .event:             return "Dates"
        case .reflection:        return "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .task:       return "circle"
        case .idea:       return "lightbulb"
        case .note:       return "text.alignleft"
        case .decision:   return "signpost.right"
        case .question:   return "questionmark.circle"
        case .waiting:    return "hourglass"
        case .commitment: return "hand.raised"
        case .event:      return "calendar"
        case .reflection: return "quote.opening"
        }
    }

    /// The order sections appear in a project. Actions first because that's what you came for;
    /// notes last because that's what you came back for.
    var sectionRank: Int {
        switch self {
        case .task, .commitment: return 0
        case .waiting:           return 1
        case .question:          return 2
        case .idea:              return 3
        case .event:             return 4
        case .decision:          return 5
        case .note, .reflection: return 6
        }
    }

    /// Lenient parse of whatever the model returned.
    ///
    /// A kind arriving from the wire decides whether something can be scheduled, so an
    /// unrecognised value must never be trusted into one of the schedulable kinds — it falls back
    /// to `.task`, which is what the app did for everything before this existed, and is therefore
    /// the one wrong answer that can't be a regression.
    static func parse(_ raw: String?) -> CaptureKind {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .task
        }
        if let exact = CaptureKind(rawValue: raw) { return exact }
        // Near-misses the model reaches for. Cheap to accept, and each one used to become a task.
        switch raw {
        case "todo", "to-do", "to_do", "action", "actionable": return .task
        case "ideas", "possibility", "suggestion", "brainstorm": return .idea
        case "notes", "fact", "reference", "info":              return .note
        case "decisions", "decided", "choice":                  return .decision
        case "questions", "unknown", "open_question":           return .question
        case "blocked", "waiting_on", "waiting-on", "delegated": return .waiting
        case "promise", "commitments", "owed":                  return .commitment
        case "appointment", "meeting", "events":                return .event
        case "vent", "venting", "feeling", "journal":           return .reflection
        default:                                                return .task
        }
    }

    /// The vocabulary handed to the model as a closed enum in the response schema.
    static var wireValues: [String] { allCases.map(\.rawValue) }
}
