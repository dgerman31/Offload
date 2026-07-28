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
        /// Low Power Mode suspends Apple Intelligence system-wide. The framework reports this as a
        /// generic "not ready", which sent people to Settings to enable something already enabled —
        /// so it gets its own state, with the one switch that actually fixes it.
        case lowPowerMode
        case unknownUnavailable

        var isAvailable: Bool { self == .available }
    }

    private(set) var state: State = .unknownUnavailable

    /// Kept only so the observation lives as long as this object does. `@ObservationIgnored`
    /// because it isn't UI state, and no `deinit` unregisters it: the closure holds `self` weakly,
    /// so the object still deallocates, and the app makes one of these for its whole lifetime.
    @ObservationIgnored private var powerObserver: (any NSObjectProtocol)?

    init() {
        refresh()
        // Low Power Mode gets toggled mid-day, usually right when the battery is low and someone
        // is capturing on the move. Reading it only at launch meant the status card confidently
        // said the wrong thing for hours.
        powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this arrives on the main thread; `assumeIsolated` states
            // that to the compiler rather than hopping to where we already are.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        switch SystemLanguageModel.default.availability {
        case .available:
            state = .available
        case .unavailable(let reason):
            // Low Power Mode outranks the framework's own reason. When it's on, it IS why the
            // model won't run, and it's the only thing the user can act on — reporting
            // "still getting ready" instead would be true-ish and useless.
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                state = .lowPowerMode
                return
            }
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
        case .lowPowerMode:                 return "Low Power Mode has Apple Intelligence paused."
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
        case .lowPowerMode:                 return "Turn it off in Settings › Battery to organize captures as you speak. Keep it on and Offload still saves every word, then sorts them out later."
        case .unknownUnavailable:           return "Try again in a moment."
        }
    }
}
