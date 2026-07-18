import AppIntents

/// Hands-free capture from the lock screen: "Hey Siri, tell Offload…". Unlike
/// `CaptureIntent` (Action Button → foregrounds the app), this one has NO
/// `openAppWhenRun`, so Siri collects the thought as a spoken parameter and the whole
/// pipeline — persist raw, extract, organize — runs in the background without unlocking.
/// This is the closest iOS allows to true locked-screen capture.
struct DictateCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Offload"
    static let description = IntentDescription(
        "Capture and organize a thought without opening the app."
    )

    @Parameter(title: "Thought", requestValueDialog: "What's on your mind?")
    var thought: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$thought)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "I didn't catch that — try again.")
        }

        do {
            let outcome = try await CaptureService().process(rawInput: trimmed, inputType: "voice")
            if let project = outcome.projectTitle {
                return .result(dialog: "Added \(outcome.addedTasks) tasks to “\(project)”.")
            }
            return .result(dialog: outcome.addedTasks == 1
                ? "Got it — added “\(outcome.taskTitles.first ?? "1 task")”."
                : "Got it — added \(outcome.addedTasks) tasks.")
        } catch {
            // The raw words were persisted before extraction was attempted (no data loss);
            // they'll be organized on a later retry.
            return .result(dialog: "Saved your words — I'll organize them once the on-device AI is ready.")
        }
    }
}
