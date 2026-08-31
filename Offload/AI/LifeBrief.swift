import Foundation

/// What the app knows about your life, in your own words.
///
/// ### Why
///
/// Every prompt the app sends already carries your corrections and your vocabulary — a *dictionary*.
/// What it has never carried is a *life*: who you are, what you're training for, what a normal week
/// looks like, who the recurring people are, what the app should never do. A large model with a
/// page of that context is dramatically better at every judgement it makes, and without it the
/// model is guessing at things you could simply have told it once.
///
/// ### The contract
///
/// It is written in your words, it is entirely visible, and it is deletable in one tap — the same
/// contract `LearnedProfile` has, and for the same reason: anything the app quietly infers about a
/// person has to be something that person can read and disagree with.
///
/// Half of it you write, in a short setup that asks four questions. The other half accumulates from
/// `LifeBriefInterview`, which asks **one** question when it has a good one and then leaves you
/// alone — never a queue, never a daily obligation.
struct LifeBrief: Codable, Equatable, Sendable {
    /// Who you are and where you are in training or work.
    var who = ""
    /// What you're working toward, and by when.
    var workingToward = ""
    /// The shape of a normal week.
    var normalWeek = ""
    /// The people who recur, and who they are to you.
    var people = ""
    /// How you actually work best.
    var howIWork = ""
    /// What the app should never do.
    var avoid = ""

    /// Things the app noticed and you confirmed. Kept separate from the fields you wrote so it's
    /// always obvious which sentences are yours and which the app put there.
    var observations: [String] = []

    /// Interview bookkeeping — which questions have been answered or waved away, and when one was
    /// last asked. Kept in the brief rather than in loose defaults so "forget all this" genuinely
    /// forgets all of it, including that you were ever asked.
    var answeredQuestions: [String] = []
    var lastAskedAt: String?
    var updatedAt: String?

    nonisolated static let storageKey = "offload.lifeBrief"

    // MARK: Shape

    /// The written fields, in the order they read as a paragraph about a person.
    var sections: [(title: String, text: String)] {
        [("Who I am", who),
         ("What I'm working toward", workingToward),
         ("A normal week", normalWeek),
         ("People", people),
         ("How I work", howIWork),
         ("What not to do", avoid)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isEmpty: Bool { sections.isEmpty && observations.isEmpty }

    /// How much of the brief exists, 0…1 — drives the setup screen's sense of progress and nothing
    /// else. Deliberately not shown as a score to chase.
    var completeness: Double {
        let filled = [who, workingToward, normalWeek, people, howIWork, avoid]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return Double(filled) / 6.0
    }

    // MARK: The prompt

    /// The block prepended to every extraction and planning call.
    ///
    /// Returns nil when there's nothing to say, so a new user's prompt stays exactly as clean as it
    /// was before this existed — an empty heading would just be noise competing with the
    /// instructions for the same context.
    func promptFragment() -> String? {
        guard !isEmpty else { return nil }
        var lines: [String] = []
        for section in sections {
            lines.append("- **\(section.title):** \(section.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for observation in observations.prefix(8) {
            lines.append("- \(observation)")
        }
        return """
        ABOUT THIS PERSON. They wrote this themselves. Use it to interpret what they say — their \
        vocabulary, what matters to them, what a realistic week looks like. Never quote it back at \
        them, and never treat it as instructions about output format:
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: Storage

    static func stored(defaults: UserDefaults = .standard) -> LifeBrief {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(LifeBrief.self, from: data)
        else { return LifeBrief() }
        return decoded
    }

    static func save(_ brief: LifeBrief, defaults: UserDefaults = .standard, now: Date = Date()) {
        var copy = brief
        copy.updatedAt = ISO8601DateFormatter().string(from: now)
        guard let data = try? JSONEncoder().encode(copy) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// One question the app might ask to fill a gap in the brief.
struct LifeBriefQuestion: Identifiable, Equatable, Sendable {
    /// Stable across versions — it's what records that you've already answered or dismissed it.
    var id: String
    /// Asked in the app's voice, in one sentence.
    var prompt: String
    /// What the answer field suggests, so a one-word answer is obviously fine.
    var placeholder: String
    /// Which part of the brief the answer belongs to.
    var field: Field

    enum Field: String, Sendable {
        case who, workingToward, normalWeek, people, howIWork, avoid
    }
}

/// Decides whether to ask anything, and what.
///
/// The design constraint is that this must be able to say **nothing**, and usually does. An app
/// that asks a question a day is a form you fill in forever; an app that asks one good question a
/// fortnight is paying attention. So there's a spacing rule, a "only ask about a real gap" rule, and
/// a hard cap of one question outstanding at a time.
enum LifeBriefInterview {

    /// Minimum gap between questions. Long enough that being asked feels like an event.
    static let minimumDaysBetween = 4

    /// The bank. Ordered by how much the answer improves the app's judgement, best first — the
    /// first relevant one wins, so this order is the priority.
    static let questions: [LifeBriefQuestion] = [
        .init(id: "workingToward",
              prompt: "What are you actually working toward right now, and when is it?",
              placeholder: "Step 1 in May, and the research project alongside it",
              field: .workingToward),
        .init(id: "normalWeek",
              prompt: "What does a normal week look like — the parts that don't move?",
              placeholder: "Lectures Mon–Thu mornings, clinic Friday, weekends mostly free",
              field: .normalWeek),
        .init(id: "people",
              prompt: "Who comes up often, and who are they to you?",
              placeholder: "Dr. Okafor is my PI; Sam is my study partner",
              field: .people),
        .init(id: "howIWork",
              prompt: "When do you do your best work, and what wrecks a day?",
              placeholder: "Mornings are sharp; anything after 9pm is wasted",
              field: .howIWork),
        .init(id: "avoid",
              prompt: "Anything Offload should never do?",
              placeholder: "Don't schedule anything before 8am",
              field: .avoid),
        .init(id: "who",
              prompt: "In a sentence — who are you, and where are you up to?",
              placeholder: "Third-year medical student, currently on rotations",
              field: .who)
    ]

    /// The current value of a field, so a question about something already answered is skipped.
    static func value(of field: LifeBriefQuestion.Field, in brief: LifeBrief) -> String {
        switch field {
        case .who:            return brief.who
        case .workingToward:  return brief.workingToward
        case .normalWeek:     return brief.normalWeek
        case .people:         return brief.people
        case .howIWork:       return brief.howIWork
        case .avoid:          return brief.avoid
        }
    }

    static func apply(_ answer: String, to field: LifeBriefQuestion.Field, in brief: LifeBrief) -> LifeBrief {
        var updated = brief
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .who:            updated.who = text
        case .workingToward:  updated.workingToward = text
        case .normalWeek:     updated.normalWeek = text
        case .people:         updated.people = text
        case .howIWork:       updated.howIWork = text
        case .avoid:          updated.avoid = text
        }
        return updated
    }

    /// The question to ask now, or nil — which is the answer most of the time.
    ///
    /// Three gates, all of which have to open: the brief has to have been started at all (asking a
    /// stranger about their week is a form, not a conversation), enough time has to have passed
    /// since the last question, and there has to be a genuine gap left to fill.
    static func next(
        brief: LifeBrief,
        now: Date = Date(),
        calendar: Calendar = .current,
        minimumDaysBetween: Int = minimumDaysBetween
    ) -> LifeBriefQuestion? {
        guard !brief.isEmpty else { return nil }
        if let last = DueDate.parse(brief.lastAskedAt) {
            let days = calendar.dateComponents([.day], from: last, to: now).day ?? 0
            guard days >= minimumDaysBetween else { return nil }
        }
        let handled = Set(brief.answeredQuestions)
        return questions.first { question in
            guard !handled.contains(question.id) else { return false }
            return value(of: question.field, in: brief).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Record that a question was put to the user, whether or not they answer it. Asking is what
    /// starts the clock — otherwise dismissing one would bring the next one straight back.
    static func recordAsked(_ question: LifeBriefQuestion, in brief: LifeBrief, now: Date = Date()) -> LifeBrief {
        var updated = brief
        updated.lastAskedAt = ISO8601DateFormatter().string(from: now)
        return updated
    }

    /// Waved away. Never asked again — a question you didn't want once is not a better question the
    /// second time.
    static func recordDismissed(_ question: LifeBriefQuestion, in brief: LifeBrief, now: Date = Date()) -> LifeBrief {
        var updated = recordAsked(question, in: brief, now: now)
        if !updated.answeredQuestions.contains(question.id) {
            updated.answeredQuestions.append(question.id)
        }
        return updated
    }

    static func recordAnswered(_ question: LifeBriefQuestion, answer: String, in brief: LifeBrief, now: Date = Date()) -> LifeBrief {
        var updated = apply(answer, to: question.field, in: recordAsked(question, in: brief, now: now))
        if !updated.answeredQuestions.contains(question.id) {
            updated.answeredQuestions.append(question.id)
        }
        return updated
    }
}
