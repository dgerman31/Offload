import AppIntents

/// Action Button → App Shortcut → this intent (spec §7). `openAppWhenRun` foregrounds
/// Offload to the capture screen; a third-party app can't silently record from a button
/// press, so this is the correct, honest model (spec §0).
struct CaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Capture"
    static var description = IntentDescription("Capture a thought and let Offload organize it into tasks.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureCoordinator.shared.beginCapture()
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
    }
}
