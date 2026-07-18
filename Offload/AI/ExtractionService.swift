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
        Infer priority from the user's language intensity, not your own judgment.

        contextTags: choose ONLY from this set, and add every tag that clearly applies —
        home, work, car, outside, store, gym, phone, computer, meeting, errands.
        Examples: "reply to a text" → [phone]; "buy milk" → [store, errands]; "at the gym" → [gym];
        "email the report" → [computer, work].

        suggestedProject: return a name ONLY when the capture describes a genuine multi-step \
        endeavor spanning several related tasks (planning a party, a trip, a move, a launch). \
        For everyday single tasks or a couple of unrelated errands, return nil. Most captures are NOT projects.
        """
    }

    /// Extract structured tasks from a raw transcript. Throws `modelUnavailable` if the
    /// on-device model can't run right now (the caller persists the raw transcript and retries).
    func extract(from transcript: String) async throws -> ExtractedCapture {
        guard case .available = SystemLanguageModel.default.availability else {
            throw ExtractionError.modelUnavailable
        }

        let session = LanguageModelSession(instructions: Self.instructions(now: Date()))
        let result = try await session.respond(
            to: transcript,
            generating: ExtractedCapture.self,
            options: GenerationOptions(temperature: 0.2)   // low = consistent extraction
        )
        return result.content   // typed ExtractedCapture — no parsing
    }
}
