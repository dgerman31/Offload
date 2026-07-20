import Foundation
import FoundationModels
import GRDB

/// Runs core extraction through the on-device model (spec §3.2 / §9). One fresh
/// `LanguageModelSession` per capture (spec §9: don't accumulate unrelated context),
/// low temperature for consistent extraction. Instructions are built per-call so the
/// model is grounded in the current time (relative-timing reasoning).
@MainActor
final class ExtractionService: TaskExtracting {

    enum ExtractionError: Error, LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "On-device AI is unavailable — your words were saved and will be organized when it's ready."
            }
        }
    }

    private let db: AppDatabase

    init(db: AppDatabase = .shared) {
        self.db = db
    }

    /// Recent corrections rendered as few-shot guidance, so the model adopts this user's
    /// filing habits instead of repeating a mistake they've already fixed by hand.
    private func personalizationFragment() async -> String? {
        let data = try? await db.dbQueue.read { database in
            (try Correction.order(Column("created_at").desc).limit(40).fetchAll(database),
             try TaskItem.filter(Column("deleted") == false).fetchAll(database))
        }
        guard let (corrections, tasks) = data else { return nil }
        return Personalization.promptFragment(Personalization.lessons(corrections: corrections, tasks: tasks))
    }

    /// Built fresh each call so the model knows "now" and can resolve relative timing.
    private static func instructions(now: Date) -> String {
        let nowStr = ISO8601DateFormatter().string(from: now)
        return """
        You turn a user's quick voice or text capture into the tasks they actually MEAN. \
        Extract INTENT, not words: figure out what the user needs to DO, never echo their \
        phrasing back at them.

        The current date and time is \(nowStr). Resolve relative timing against it and set \
        dueDate (ISO 8601) accordingly:
        - "right now", "rn", "on my way", "heading to", "about to" → within the next hour (≈ now + 1 hour).
        - "later", "later today", "this evening" → this evening, today.
        - "tonight" → around 20:00 today.
        - "tomorrow" → the next day; "this weekend" → the coming Saturday.
        Only set dueDate or recurrenceRule when the user actually implies timing — otherwise leave them nil.

        CAPTURE WHAT WAS SAID — NEVER INVENT A PLAN. This is the most important rule.
        You are recording the user's thoughts, not designing a strategy to achieve them.
        - NEVER output a task the user did not actually mention. Do not generate the "obvious"
          steps toward a goal. If they mention 3 things, you produce 3 tasks — not 5, not 8.
        - NEVER invent a dueDate. Only set one when the user stated or clearly implied timing.
          No timing words in the capture means dueDate is nil for every task.
        - NEVER invent effortMinutes. Only estimate when the user indicated a duration.
        - "Create a project/list/folder for X" means make an EMPTY CONTAINER named X. It does
          NOT mean plan how to accomplish X. Return suggestedProject "X" plus ONLY whatever
          other tasks the user actually named — often none at all.
        - Do NOT emit generic lifecycle filler like "Research X", "Design X", "Develop X",
          "Test X", "Launch X", "Plan X", "Review X" unless the user said those words.
        - When someone lists features or changes they want, each thing they asked for is ONE
          task, phrased as they asked for it. Don't decompose it into how you'd build it.
        If you're unsure whether the user said something, leave it out. A short, faithful
        capture is always better than a rich, invented one.

        TURN THOUGHTS INTO ACTIONS:
        - Invert problem statements into the action that fixes them: "I left my jacket in
          school" → "Retrieve jacket from school". "The kitchen is a disaster" → "Clean kitchen".
        - Strip the meta-frame; keep the underlying action: "I keep forgetting to call mom" →
          "Call mom" (habitual "keep forgetting" may imply a recurrence). "Remember to pay
          bills" → "Pay bills". "Stop procrastinating on the deck" → "Build deck". Never
          produce a task about remembering, forgetting, trying, or procrastinating.
        - Make vague intents executable — name the concrete next step: "think about the Q3
          roadmap" → "Draft Q3 roadmap outline". "Catch up with Sarah" → "Schedule catch-up
          with Sarah". A question to settle ("should I hire Bob?") → "Decide on Bob hire".
        - Worry usually hides a controllable action: "I'm nervous about the interview" →
          "Practice interview answers".
        - Commitments to people are tasks with a recipient: "I owe Sarah feedback" → "Send
          feedback to Sarah". "Waiting on design" → "Follow up with design team".
        - Pure venting with no action the user owns ("I'm terrible at email", "my manager
          never listens") → NO task at all. Only extract what the user can actually do.
        Titles are short, action-first verb phrases; a stranger should know exactly what
        "done" looks like. Split compound thoughts into separate tasks.

        details: the title stays short — put the specifics HERE instead of inflating the title
        or inventing extra tasks. Names, numbers, constraints, who it's for, and any wording
        worth keeping from the capture belong in details. Use ONLY what the user actually
        said; never pad it with your own advice or steps. Leave it nil when the title already
        says everything ("Buy milk" needs no details).
        Example: "tell the landlord the sink is leaking again, third time this year, he said
        to text not call" → title "Text landlord about leaking sink", details "Third leak this
        year. He asked to be texted rather than called."

        priority: weigh THREE signals together, not just how loud the words are —
        - Consequence: what happens if it slips? Bills, rent, taxes, deadlines, health,
          medication, and things owed to other people are high even when phrased calmly.
        - Urgency: due today or already overdue leans high; no time pressure leans low.
        - Intensity: "really need to", "urgent", "ASAP", "don't forget" push higher; "maybe",
          "someday", "at some point", "would be nice" pull lower.
        high = important AND time-sensitive or high-consequence ("pay rent", "renew passport
        before the trip", "call the doctor back"). medium = a normal actionable to-do with no
        strong pressure (the sensible default). low = optional, vague, or someday/maybe ("might
        reorganize the garage", "look into a new podcast"). When unsure, choose medium.

        contextTags: choose ONLY from this set, and add every tag that clearly applies —
        home, work, car, outside, store, gym, phone, computer, meeting, errands.
        Examples: "reply to a text" → [phone]; "buy milk" → [store, errands]; "at the gym" → [gym];
        "email the report" → [computer, work].

        MATCH THE STRUCTURE TO THE COMPLEXITY. Give simple things a simple shape and complex
        things a fuller one — never inflate an errand, never flatten a real project.
        - Atomic (most captures): a single action → ONE task, NO subtasks, no project.
          "buy milk", "go to the store to buy milk", "email the report", "text Sarah back",
          "call the dentist to book" → one task each. Do NOT invent steps like "Go to the
          store" / "Pay" — those are implied, not distinct tasks.
        - Multi-step task: ONE action that genuinely has 2+ DISTINCT sub-steps → one task with
          those steps as subtasks. Never let a subtask merely restate the task.
          "go home and grab my charger, the files, and water the plants" → task "Go home" with
          subtasks ["Grab charger", "Grab files", "Water plants"].
          "prep for tomorrow's client presentation" → task "Prep client presentation" with
          subtasks ["Pull latest numbers", "Build the slides", "Rehearse the walkthrough"].
          If you cannot name at least two genuinely separate steps, emit NO subtasks.
        - Project: a real endeavor spanning several related tasks (a trip, a move, a launch, a
          party) → set suggestedProject and emit multiple tasks; decompose an individual task
          into subtasks only when it too is genuinely multi-step. The bigger and more involved
          the capture, the more tasks/subtasks it warrants.
          "start planning mom's surprise party — book a venue, order the cake, send invites" →
          suggestedProject "Mom's surprise party" with tasks "Book venue", "Order cake",
          "Send invites". A weekend move might yield 6–8 tasks, some with their own subtasks.
        Everyday single tasks and a couple of unrelated errands are NOT a project — return nil.

        people: list anyone the task genuinely involves — someone you owe something to, are
        meeting, or need to contact. Use their name exactly as said ("Sarah", "mom", "Dr.
        Patel"). "Send Sarah the deck" → ["Sarah"]. "Call mom back" → ["mom"]. "Buy milk" →
        empty. Never invent a name, and don't list people merely mentioned in passing.

        isAppointment: set true ONLY for a real calendar event happening at a specific time —
        a meeting, doctor's appointment, reservation, or a call scheduled for a set time. Leave
        it false for ordinary to-dos, errands, and reminders, even when they have a due date.
        "dentist at 3pm Tuesday" → isAppointment true. "call the dentist to book" → false.
        "buy milk tomorrow" → false.

        Worked examples:
        1) "I really need to email the quarterly report before I leave work today, then pick up \
        milk on the way home" → task "Email quarterly report" (Work, high, [computer, work], due \
        today near end of workday) + task "Buy milk" (Personal, medium, [store, errands]); no \
        subtasks, no project.
        2) "start planning mom's surprise party — book a venue, order the cake, send invites" → \
        suggestedProject "Mom's surprise party" with tasks "Book venue", "Order cake", "Send invites".
        3) "maybe someday reorganize the garage" → one task, low priority, category Personal, no \
        dueDate, no subtasks, no project.
        4) "rent's due friday" → one task "Pay rent" (Finance, high — a bill with a deadline), \
        dueDate Friday; no subtasks.
        5) "I left my jacket in school" → one task "Retrieve jacket from school" (Personal, \
        medium) — the fix, not the mishap; no subtasks.
        6) "I keep forgetting to call mom" → one task "Call mom" (Personal, medium, [phone]) — \
        the action, never a task about forgetting.
        7) "ugh, this codebase is such a mess" → no task — venting without a committed action.
        8) "create a project for future app ideas, I want to add subfolders into projects, and \
        create a details field for tasks" → suggestedProject "Future App Ideas" with EXACTLY \
        two tasks: "Add subfolders to projects" and "Add details field to tasks". No dueDate, \
        no effortMinutes (none were implied), no subtasks. Do NOT invent "Research app \
        management systems", "Design app architecture", "Develop app features", "Test app \
        functionality" or "Launch app" — the user never said any of that.
        9) "brainstorm names for the newsletter" → one task "Brainstorm newsletter names". \
        Not a project, no steps, no due date.

        When the user implies timing on a specific day, call checkCalendarAvailability for that \
        date and pick a due time that avoids the busy windows.
        """
    }

    /// UserDefaults key for the "think longer" toggle exposed in Settings.
    nonisolated static let deliberateModeKey = "offload.deliberateMode"

    /// Extract structured tasks from a raw transcript. Throws `modelUnavailable` if the
    /// on-device model can't run right now (the caller persists the raw transcript and retries).
    ///
    /// Deliberate mode (spec: trade time for quality on a small model): first let the model
    /// reason about the capture in plain text, then extract in a second turn of the same
    /// session so that reasoning informs the structured output. ~2x slower, better on the
    /// hard cases (compound thoughts, ambiguous timing, project-or-not).
    func extract(from transcript: String) async throws -> ExtractedCapture {
        guard case .available = SystemLanguageModel.default.availability else {
            throw ExtractionError.modelUnavailable
        }

        // Base instructions plus anything this user has taught us by correcting the model,
        // plus any categories they've defined for themselves.
        var instructions = Self.instructions(now: Date())
        let custom = CustomCategories.load()
        if !custom.isEmpty {
            instructions += "\n\nThis user has added their own categories: \(custom.joined(separator: ", ")). "
                + "Use one of those when it genuinely fits better than the standard set."
        }
        if let learned = await personalizationFragment() {
            instructions += "\n\n" + learned
        }

        let session = LanguageModelSession(
            tools: [CalendarAvailabilityTool()],
            instructions: instructions
        )

        if UserDefaults.standard.bool(forKey: Self.deliberateModeKey) {
            // Pass 1: think out loud (the reasoning stays in the session's context).
            _ = try await session.respond(to: """
                Before extracting, reason step by step about this capture: what does the user \
                actually need to DO (invert any problem statement into its fix; strip frames \
                like "remember to" or "keep forgetting"; or is it just venting with no action?), \
                how many distinct tasks are there, what timing (if any) is implied and its \
                concrete date/time, and is this a genuine multi-step project or just \
                individual tasks?
                Capture: \(transcript)
                """)
            // Pass 2: extract, informed by that reasoning.
            let result = try await session.respond(
                to: "Now produce the structured tasks for that capture.",
                generating: ExtractedCapture.self,
                options: GenerationOptions(temperature: 0.2)
            )
            return result.content
        }

        let result = try await session.respond(
            to: transcript,
            generating: ExtractedCapture.self,
            options: GenerationOptions(temperature: 0.2)   // low = consistent extraction
        )
        return result.content   // typed ExtractedCapture — no parsing
    }
}
