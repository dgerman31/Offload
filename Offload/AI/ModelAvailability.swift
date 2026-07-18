import Foundation
import FoundationModels

/// Wraps `SystemLanguageModel.default.availability` (spec §2.2) into a simple,
/// UI-friendly state plus a human-readable explanation and the single action that
/// fixes it (spec §5.6: "state what's missing and the one action that fixes it").
@MainActor
@Observable
final class ModelAvailability {
    enum State: Equatable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknownUnavailable

        var isAvailable: Bool { self == .available }
    }

    private(set) var state: State = .unknownUnavailable

    init() {
        refresh()
    }

    func refresh() {
        switch SystemLanguageModel.default.availability {
        case .available:
            state = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                state = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                state = .appleIntelligenceNotEnabled
            case .modelNotReady:
                state = .modelNotReady
            @unknown default:
                state = .unknownUnavailable
            }
        }
    }

    /// One-line status for the first-run / Settings screen (spec §5.6).
    var headline: String {
        switch state {
        case .available:                    return "On-device AI ready — nothing leaves your phone."
        case .deviceNotEligible:            return "This device can't run on-device AI."
        case .appleIntelligenceNotEnabled:  return "Apple Intelligence is turned off."
        case .modelNotReady:                return "The on-device model is still getting ready."
        case .unknownUnavailable:           return "On-device AI is currently unavailable."
        }
    }

    /// The single corrective action to surface, or nil when everything's fine.
    var fixAction: String? {
        switch state {
        case .available:                    return nil
        case .deviceNotEligible:            return "Offload can still capture your words; AI organizing needs a newer iPhone."
        case .appleIntelligenceNotEnabled:  return "Turn on Apple Intelligence in Settings, then reopen Offload."
        case .modelNotReady:                return "Give it a moment — it warms up shortly after enabling. Pull to retry."
        case .unknownUnavailable:           return "Try again in a moment."
        }
    }
}
