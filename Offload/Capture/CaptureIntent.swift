import AppIntents

/// Action Button → App Shortcut → this intent (spec §7). `openAppWhenRun` foregrounds
/// Offload to the capture screen; a third-party app can't silently record from a button
/// press, so this is the correct, honest model (spec §0).
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Capture"
    static let description = IntentDescription("Capture a thought and let Offload organize it into tasks.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Action Button → open the capture sheet already listening (spec §2.3 auto-record).
        CaptureCoordinator.shared.beginCapture(autoListen: true)
        return .result()
    }
}

/// Vends the intent as an App Shortcut so it appears in Settings → Action Button,
/// and automatically in Shortcuts and Siri (spec §7).
struct OffloadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "New note in \(.applicationName)"
            ],
            shortTitle: "Capture",
            systemImageName: "bolt.circle.fill"
        )
        AppShortcut(
            intent: DictateCaptureIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "Remember this in \(.applicationName)"
            ],
            shortTitle: "Tell Offload",
            systemImageName: "waveform"
        )
        // The other direction: getting an answer out, hands-free.
        AppShortcut(
            intent: DailyBriefIntent(),
            phrases: [
                "What's on my plate in \(.applicationName)",
                "What do I have today in \(.applicationName)",
                "Ask \(.applicationName) about my day"
            ],
            shortTitle: "My day",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: CommitmentsIntent(),
            phrases: [
                "What do I owe someone in \(.applicationName)",
                "Check what I owe in \(.applicationName)"
            ],
            shortTitle: "What I owe",
            systemImageName: "person.2"
        )
    }
}
