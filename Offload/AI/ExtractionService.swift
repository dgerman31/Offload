import Foundation
import FoundationModels

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

    /// Built fresh each call so the model knows "now" and can resolve relative timing.
    private static func instructions(now: Date) -> String {
        let nowStr = ISO8601DateFormatter().string(from: now)
        return """
        You turn a user's quick voice or text capture into actionable tasks.

        The current date and time is \(nowStr). Resolve relative timing against it and set \
        dueDate (ISO 8601) accordingly:
        - "right now", "rn", "on my way", "heading to", "about to" → within the next hour (≈ now + 1 hour).
        - "later", "later today", "this evening" → this evening, today.
        - "tonight" → around 20:00 today.
        - "tomorrow" → the next day; "this weekend" → the coming Saturday.
        Only set dueDate or recurrenceRule when the user actually implies timing — otherwise leave them nil.

        Split compound thoughts into separate tasks. Keep titles short and action-first.

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

        let session = LanguageModelSession(
            tools: [CalendarAvailabilityTool()],
            instructions: Self.instructions(now: Date())
        )

        if UserDefaults.standard.bool(forKey: Self.deliberateModeKey) {
            // Pass 1: think out loud (the reasoning stays in the session's context).
            _ = try await session.respond(to: """
                Before extracting, reason step by step about this capture: how many distinct \
                tasks are there, what timing (if any) is implied and its concrete date/time, \
                and is this a genuine multi-step project or just individual tasks?
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
