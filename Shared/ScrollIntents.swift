import AppIntents

/// The two buttons on the scroll bar.
///
/// `LiveActivityIntent`, so a tap runs in the app's process without foregrounding it — pressing
/// "Quiet 15m" from the Lock Screen must not yank you into Offload, which would be its own kind of
/// interruption. `isDiscoverable = false` keeps them out of Shortcuts: they're controls on a
/// widget, not actions to script.
struct SnoozeScrollGuardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Quiet for 15 minutes"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        ScrollCommandBus.send(.snooze)
        return .result()
    }
}

/// "I've stopped." Ends the session and takes the ladder down with it — the honest button for the
/// case where you closed the feed before the app noticed.
struct StopScrollGuardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "I'm done scrolling"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        ScrollCommandBus.send(.stop)
        return .result()
    }
}
