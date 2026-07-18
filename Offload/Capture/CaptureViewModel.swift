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

    private let service: CaptureService

    init(service: CaptureService = CaptureService()) {
        self.service = service
    }

    var isProcessing: Bool { phase == .processing }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    /// Run the pipeline on the current text. On success we surface a count; on failure the
    /// raw text is preserved (both in the DB and on screen) so nothing is lost.
    func save() async {
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
        text = ""
        phase = .editing
    }
}
