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

    /// The system prompt. Deliberately compact: the on-device model has a small context
    /// window (~4k tokens shared with the capture and the output schema), and the deterministic
    /// guards in `CaptureMapper` — dropping invented dates, refusing night-time hours, blocking
    /// "arrange a meeting" from the calendar, stripping fluff — enforce the hard rules anyway,
    /// so the prompt only has to steer, not police. Built fresh each call for the current time.
    /// `nonisolated` and `internal` so the prompt-budget test can guard its size in CI.
    nonisolated static func instructions(now: Date, categories: [String]) -> String {
        let nowStr = ISO8601DateFormatter().string(from: now)
        return """
        Convert a quick voice/text capture into the tasks the user actually means. Now: \(nowStr) \
        (use only to resolve time words they actually said).

        Core rules:
        - Capture only what they said. Never invent tasks, steps, dates, or effort. 3 things \
        mentioned = 3 tasks. "Create a project for X" = an empty project named X plus only the \
        tasks they named — never a generic research/design/build/launch plan.
        - Extract the action, not the words: "left my jacket at school" → "Retrieve jacket from \
        school"; "keep forgetting to call mom" → "Call mom". Never a task about \
        remembering/forgetting/trying. Pure venting with no action → no task.
        - title: short action phrase. details: names/numbers/context worth keeping, from their \
        words only, else nil.
        - dueDate: nil unless they said when. A day with no stated time is that date at 00:00 \
        (all-day), not a morning. Resolve tomorrow/tonight/next week against now. Never choose \
        an hour between 10pm–7am unless they named a night time.
        - deadline (when it MUST be done: "due Friday") is separate from dueDate (when they'll \
        do it). Set only what they stated; leave the other nil.
        - priority: high only if important AND time-sensitive or high-consequence \
        (bills, health, owed to someone); low for someday/maybe; else medium.
        - category = area of their life, not subject (a clinician's scans = Work). Pick one of: \
        \(categories.joined(separator: ", ")).
        - contextTags from: home, work, car, outside, store, gym, phone, computer, meeting, errands.
        - people: names the task involves, exactly as said, else empty.
        - subtasks only when one task has 2+ genuinely distinct steps. suggestedProject only \
        for a real multi-task endeavour.
        - isAppointment = true ONLY if the event already exists AND has a stated time. \
        "Schedule/book/set up a meeting" is arranging one → false.

        Examples:
        "rent's due friday" → "Pay rent" (Finance, high), deadline Friday, no dueDate time.
        "schedule a meeting with Dr Patel and review the scans" → "Schedule meeting with Dr \
        Patel" (isAppointment false) + "Review scans" (Work); no dueDate on either.
        "planning mom's party — venue, cake, invites" → project "Mom's party" + tasks Book \
        venue, Order cake, Send invites.
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

        do {
            return try await runExtraction(transcript: transcript, lean: false)
        } catch {
            // A long capture plus personalization can still overflow the small on-device
            // window. Rather than fail outright — the user's words are saved either way —
            // retry once with the barest possible prompt: no learned examples, no deliberate
            // pass. Better a plainer extraction than none.
            if Self.isContextOverflow(error) {
                return try await runExtraction(transcript: transcript, lean: true)
            }
            throw error
        }
    }

    /// One extraction attempt. `lean` drops everything optional to fit the context window.
    private func runExtraction(transcript: String, lean: Bool) async throws -> ExtractedCapture {
        var instructions = Self.instructions(now: Date(), categories: CustomCategories.all())
        // Personalization is valuable but expendable — only when we have budget to spare.
        if !lean, let learned = await personalizationFragment() {
            instructions += "\n\nThis user's past corrections (follow them):\n" + learned
        }

        // No calendar tool: a tool round-trip consumes scarce context, and the planner now does
        // the real scheduling-around-your-calendar work anyway.
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2)   // low = consistent extraction

        // Deliberate mode (a reasoning pass first) only when not already trimming for space —
        // the extra turn is exactly what tips a borderline capture over the edge.
        if !lean, UserDefaults.standard.bool(forKey: Self.deliberateModeKey) {
            _ = try await session.respond(to: "Briefly reason about what the user needs to do, "
                + "then wait. Capture: \(transcript)")
            let result = try await session.respond(
                to: "Now output the structured tasks.",
                generating: ExtractedCapture.self, options: options)
            return result.content
        }

        let result = try await session.respond(
            to: transcript, generating: ExtractedCapture.self, options: options)
        return result.content   // typed ExtractedCapture — no parsing
    }

    /// Whether an error is the on-device model running out of context window. Matched on the
    /// error's description rather than a specific enum case, so it survives SDK naming changes.
    private static func isContextOverflow(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("context") && (text.contains("window") || text.contains("exceed") || text.contains("size"))
    }
}
