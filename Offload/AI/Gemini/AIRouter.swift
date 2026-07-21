import Foundation

/// The single gate every cloud AI call passes through.
///
/// It decides — once, consistently — whether a Gemini call should happen at all (is there a
/// key? is there budget left today?) and runs it if so, handing back `nil` when the cloud isn't
/// available so callers fall back to the on-device model. Errors never propagate as crashes:
/// a failed call refunds its budget, records the reason for Settings, and returns nil.
///
/// This is what makes "Gemini almost always, Apple only as a safety net" a one-line decision at
/// every call site instead of scattered conditionals.
@MainActor
final class AIRouter {
    static let shared = AIRouter()

    /// Preference key: when on, the app stays fully on-device (private mode) and never calls out.
    static let onDeviceOnlyKey = "offload.ai.onDeviceOnly"

    /// The last cloud failure, surfaced in Settings so a wrong key or dead network is diagnosable.
    private(set) var lastError: String?
    private(set) var lastSucceeded = false

    /// Is the cloud a live option right now? (Key present and the user hasn't forced on-device.)
    var cloudAvailable: Bool {
        SecretStore.hasGeminiKey && !UserDefaults.standard.bool(forKey: Self.onDeviceOnlyKey)
    }

    /// Run a Gemini operation if allowed. Returns nil — meaning "fall back to on-device" — when
    /// there's no key, the private-mode switch is on, we're over budget, or the call fails.
    /// The API key is injected so no call site touches the Keychain directly.
    func run<T>(label: String, _ body: (String) async throws -> T) async -> T? {
        guard cloudAvailable, let key = SecretStore.geminiKey else { return nil }
        guard await AIBudget.shared.reserve() else {
            lastError = "Daily/'per-minute AI limit reached — using on-device."
            return nil
        }
        do {
            let result = try await body(key)
            lastSucceeded = true
            lastError = nil
            return result
        } catch {
            await AIBudget.shared.refund()
            lastSucceeded = false
            lastError = "\(label): \(error.localizedDescription)"
            return nil
        }
    }

    /// Requests used against today's quota, for the Settings readout.
    func usedToday() async -> Int { await AIBudget.shared.usedToday() }
}
