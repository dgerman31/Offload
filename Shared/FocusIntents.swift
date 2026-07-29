import AppIntents

/// The buttons on the Lock Screen and in the Dynamic Island.
///
/// In `Shared` because `Button(intent:)` needs these types compiled into the widget extension,
/// while the work they trigger has to happen in the app — see `FocusCommandBus` for why that
/// split exists and how it's bridged.
///
/// `LiveActivityIntent` rather than `AppIntent`: the system runs these in the **app's** process
/// without foregrounding it, so a tap on the Lock Screen and a tap inside the app end up in the
/// identical code path, updating the identical clock. `isDiscoverable = false` keeps them out of
/// Shortcuts — they're controls on a widget, not actions anyone should be scripting.
struct PauseFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause focus"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusCommandBus.send(.pause)
        return .result()
    }
}

struct ResumeFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume focus"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusCommandBus.send(.resume)
        return .result()
    }
}

/// The pomodoro button: end this block early and take the break, or cut a break short and get
/// back to it.
struct SkipFocusPhaseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip to the next phase"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusCommandBus.send(.skip)
        return .result()
    }
}

/// End the whole session from the Lock Screen. Deliberately does *not* mark the task complete —
/// that's a claim about the work, and it shouldn't be made by a button you can hit in your pocket.
struct EndFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End focus session"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusCommandBus.send(.end)
        return .result()
    }
}
