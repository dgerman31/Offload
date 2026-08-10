import Foundation
import OSLog

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

    /// Why the most recent call declined to run or failed, as a typed reason rather than a
    /// message. `run` returns `nil` for six quite different situations, and the capture pipeline
    /// now has to tell the user which one it hit — "add a key" and "you're offline" call for
    /// different actions. Cleared on success.
    private(set) var lastUnavailable: ExtractionUnavailable?

    /// Is the cloud a live option right now? (Key present and the user hasn't forced on-device.)
    var cloudAvailable: Bool {
        SecretStore.hasGeminiKey && !UserDefaults.standard.bool(forKey: Self.onDeviceOnlyKey)
    }

    /// Run a Gemini operation if allowed. Returns nil when there's no key, the private-mode
    /// switch is on, we're over budget, or the call fails — recording *which* in
    /// `lastUnavailable` so the caller can say something true about it.
    /// The API key is injected so no call site touches the Keychain directly.
    func run<T>(label: String, _ body: (String) async throws -> T) async -> T? {
        // Split what `cloudAvailable` folds together: "you turned the cloud off" and "you never
        // set it up" are both `false` there, but they ask the user for opposite things.
        guard !UserDefaults.standard.bool(forKey: Self.onDeviceOnlyKey) else {
            lastUnavailable = .privateMode
            return nil
        }
        guard SecretStore.hasGeminiKey, let key = SecretStore.geminiKey else {
            lastUnavailable = .noKey
            return nil
        }
        guard await AIBudget.shared.reserve() else {
            lastUnavailable = .overBudget
            lastError = "Daily/per-minute AI limit reached."
            return nil
        }
        do {
            let result = try await body(key)
            lastSucceeded = true
            lastError = nil
            lastUnavailable = nil
            return result
        } catch {
            // A cancelled request — the view disappeared, the user navigated away mid-capture —
            // isn't a failure at all. Surfacing it as `lastError` would flash a spurious "AI
            // failed" state in Settings on every ordinary navigation, so it's carved out first and
            // never recorded as an error. The reservation is handed back since nothing was learned
            // about whether the call would have succeeded.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                await AIBudget.shared.refund()
                lastUnavailable = .cancelled
                Log.ai.debug("Gemini call for \(label, privacy: .public) cancelled — no error recorded")
                return nil
            }

            // Refund only when the request never reached Google — a `URLError`, an encoding
            // failure, or anything else thrown before the network round trip. A real HTTP
            // response, including a 429, means the call counted against the *actual* quota.
            // Refunding those unconditionally (the previous behavior) meant that the moment the
            // real quota was exhausted, the local counter started winding backwards and the app
            // kept firing requests it already knew would be rejected.
            if Self.isPreSendFailure(error) {
                await AIBudget.shared.refund()
            } else if let gemini = error as? GeminiError, case .http(429, _, _) = gemini {
                // TODO(AIBudget): there's no method to fast-forward today's counter to its
                // ceiling — only reserve/refund/usedToday exist. Until one's added, a real 429 at
                // least stops being refunded (the fix above), but the app will keep trying until
                // the per-minute/per-day counters organically catch up rather than stopping
                // immediately. Needs a new AIBudget method (e.g. `exhaustToday()`); out of scope
                // for this change since AIBudget.swift isn't in this file list.
                Log.ai.error("Gemini quota exhausted (429) for \(label, privacy: .public) — budget not refunded")
            }
            lastSucceeded = false
            lastError = "\(label): \(error.localizedDescription)"
            // A pre-send failure never reached Google, which in practice means the network — say
            // "check your connection" rather than blaming the model for something it never saw.
            lastUnavailable = Self.isPreSendFailure(error)
                ? .offline(Self.kind(error))
                : .failed(error.localizedDescription)
            Log.ai.notice("Gemini call for \(label, privacy: .public) unavailable: kind \(Self.kind(error), privacy: .public)")
            return nil
        }
    }

    /// Did this failure happen before the request reached Google? If so, the local budget
    /// reservation was never actually spent against the real quota and should be handed back. If
    /// not — `.http` (any status), `.blocked`, `.emptyResponse` all mean Google answered — the
    /// call counted for real, so refunding it would let the local counter drift ahead of reality.
    private static func isPreSendFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let gemini = error as? GeminiError {
            switch gemini {
            case .noKey, .badResponse: return true
            case .http, .blocked, .emptyResponse: return false
            }
        }
        return true // e.g. a JSON encoding failure — never left the device.
    }

    /// A safe-to-log summary of an error for the Settings-adjacent diagnostics — status/error
    /// kind only, never Google's message text (which could, in principle, echo request content).
    private static func kind(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "URLError(\(urlError.code.rawValue))" }
        if let gemini = error as? GeminiError, case let .http(status, _, _) = gemini { return "http(\(status))" }
        return String(describing: type(of: error))
    }

    /// Requests used against today's quota, for the Settings readout.
    func usedToday() async -> Int { await AIBudget.shared.usedToday() }
}
