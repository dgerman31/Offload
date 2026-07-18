import SwiftUI

/// Drives the capture screen. Increment 4a covers the typed path end to end;
/// voice (TranscriptionService) is added in 4b as an additional input mode.
@MainActor
@Observable
final class CaptureViewModel {
    enum Phase: Equatable {
        case editing
        case processing
        case done(added: Int, project: String?)
        case failed(String)
    }

    var text = ""
    var phase: Phase = .editing
    var isListening = false

    private let service: CaptureService
    private let transcription = TranscriptionService()

    init(service: CaptureService = CaptureService()) {
        self.service = service
    }

    var isProcessing: Bool { phase == .processing }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    // MARK: Voice (an additional input mode — typing always remains available)

    /// Toggle dictation. Streams the live transcript into `text`, which the user can then
    /// edit or extend by typing. Voice never replaces the keyboard.
    func toggleMic() async {
        if isListening { stopListening(); return }

        guard await transcription.requestAuthorization() else {
            phase = .failed("Microphone or speech access is off. You can still type your thought.")
            return
        }
        transcription.onTranscript = { [weak self] transcript in
            self?.text = transcript
        }
        do {
            try transcription.start()
            isListening = true
            Haptics.light()
        } catch {
            isListening = false
            phase = .failed("Couldn't start the microphone. You can still type your thought.")
        }
    }

    func stopListening() {
        transcription.stop()
        isListening = false
    }

    /// Run the pipeline on the current text. On success we surface a count; on failure the
    /// raw text is preserved (both in the DB and on screen) so nothing is lost.
    func save() async {
        if isListening { stopListening() }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        phase = .processing
        Haptics.light()
        do {
            let outcome = try await service.process(rawInput: input, inputType: "text")
            Haptics.success()
            phase = .done(added: outcome.addedTasks, project: outcome.projectTitle)
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        if isListening { stopListening() }
        text = ""
        phase = .editing
    }
}
