import Foundation
import FoundationModels

/// Runs core extraction through the on-device model (spec §3.2 / §9). One fresh
/// `LanguageModelSession` per capture (spec §9: don't accumulate unrelated context),
/// low temperature for consistent extraction.
@MainActor
final class ExtractionService {

    enum ExtractionError: Error, LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "On-device AI is unavailable — your words were saved and will be organized when it's ready."
            }
        }
    }

    private static let instructions = """
        You turn a user's quick voice or text capture into actionable tasks.
        Split compound thoughts into separate tasks. Keep titles short and action-first.
        Infer priority from the user's language intensity, not your own judgment.
        Only set dueDate or recurrenceRule when the user actually implies timing.
        """

    /// Extract structured tasks from a raw transcript. Throws `modelUnavailable` if the
    /// on-device model can't run right now (the caller persists the raw transcript and retries).
    func extract(from transcript: String) async throws -> ExtractedCapture {
        guard case .available = SystemLanguageModel.default.availability else {
            throw ExtractionError.modelUnavailable
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        let result = try await session.respond(
            to: transcript,
            generating: ExtractedCapture.self,
            options: GenerationOptions(temperature: 0.2)   // low = consistent extraction
        )
        return result.content   // typed ExtractedCapture — no parsing
    }
}
