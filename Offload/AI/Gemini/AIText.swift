import Foundation
import FoundationModels

/// Freeform generation with the same "Gemini first, Apple on-device fallback" policy the rest
/// of the app uses — for the reflective, prose features: weekly insights, project briefs, the
/// morning brief. Returns nil only when neither the cloud nor the on-device model can answer,
/// so callers keep a deterministic fallback for that case.
@MainActor
enum AIText {
    static func generate(system: String, prompt: String, temperature: Double = 0.4) async -> String? {
        if let cloud = await AIRouter.shared.run(label: "text", { key in
            try await GeminiClient(apiKey: key).generateText(system: system, prompt: prompt, temperature: temperature)
        }), !cloud.isEmpty {
            return cloud
        }
        return await appleText(system: system, prompt: prompt)
    }

    /// On-device Apple Intelligence — the safety net.
    private static func appleText(system: String, prompt: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: system)
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
