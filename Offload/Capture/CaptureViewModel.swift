import SwiftUI

/// Drives the capture screen. Increment 4a covers the typed path end to end; voice
/// (TranscriptionService) is added in 4b as an additional input mode. Near-duplicates now
/// *block* on a Merge / Keep both / Skip choice before anything is saved (spec §3.5).
@MainActor
@Observable
final class CaptureViewModel {
    enum Phase: Equatable {
        case editing
        case processing
        /// Blocking review: extraction found near-duplicates the user must resolve before
        /// insertion (spec §3.5). Insertion is deferred until every candidate has a choice.
        case reviewingDuplicates(candidates: [DuplicateCandidate])
        case done(added: Int, titles: [String], project: String?, similar: [String])
        case failed(String)
    }

    var text = ""
    var phase: Phase = .editing
    var isListening = false
    /// Live mic level, 0…1, for the waveform.
    var inputLevel: Double = 0

    /// Per-candidate resolutions gathered during the `reviewingDuplicates` phase, keyed by
    /// candidate id. Insertion waits until this covers every candidate.
    var resolutions: [String: DuplicateResolution] = [:]

    /// The prepared-but-not-inserted capture awaiting a duplicate decision.
    private var pending: PreparedCapture?

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
        // Tapping the mic while listening finishes AND submits what was said.
        if isListening {
            stopListening()
            await save()
            return
        }
        await startListening()
    }

    /// Begin dictation immediately when the sheet was opened via the Action Button
    /// (spec §2.3 auto-record). Reuses the exact guarded start path as the mic button, so the
    /// Low Power Mode guard and authorization request still apply.
    func beginAutoListen() async {
        guard !isListening else { return }
        await startListening()
    }

    /// Shared mic-start path: honor the Low Power Mode guard and authorization request, then
    /// stream the transcript into `text`. Never bypasses either safety check.
    private func startListening() async {
        // Low Power Mode disables on-device speech and can crash the recognizer on start —
        // guard it out and tell the user, never attempt (and never crash).
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            phase = .failed("Turn off Low Power Mode to use voice — it disables on-device speech. You can still type.")
            return
        }
        guard await transcription.requestAuthorization() else {
            phase = .failed("Microphone or speech access is off. You can still type your thought.")
            return
        }
        // The callback now fires off the main actor — hop back before touching UI state.
        // Ignore empty results (the recognizer emits an empty "final" on stop, which would
        // otherwise wipe what the user just said).
        transcription.onTranscript = { [weak self] transcript in
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { @MainActor in self?.text = transcript }
        }
        // Fires on the audio thread; hop to main before touching observable state.
        transcription.onLevel = { [weak self] level in
            Task { @MainActor in self?.inputLevel = level }
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

    /// Stop the mic WITHOUT submitting — backs the "Type instead" control so an auto-record
    /// session can be reviewed/edited/extended by typing before a manual Save.
    func stopListening() {
        transcription.stop()
        isListening = false
        inputLevel = 0
    }

    // MARK: Save (typed + voice) — blocks on near-duplicates before insertion

    /// Run the pipeline on the current text. On success we surface a count; on failure the
    /// raw text is preserved (both in the DB and on screen) so nothing is lost. If extraction
    /// finds near-duplicates, we pause in `reviewingDuplicates` and insert nothing until the
    /// user resolves them (spec §3.5).
    func save() async {
        if isListening { stopListening() }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        phase = .processing
        Haptics.light()
        do {
            let prepared = try await service.prepare(rawInput: input, inputType: "text")
            if prepared.candidates.isEmpty {
                // Common case: nothing similar — insert straight away, no behavior change.
                let outcome = try await service.finalize(prepared, resolutions: [:])
                Haptics.success()
                phase = .done(added: outcome.addedTasks, titles: outcome.taskTitles,
                              project: outcome.projectTitle, similar: outcome.similarWarnings)
            } else {
                // Block before saving: hand the candidates to the UI for a per-item choice.
                pending = prepared
                resolutions = [:]
                Haptics.warning()
                phase = .reviewingDuplicates(candidates: prepared.candidates)
            }
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Record the user's choice for one duplicate candidate.
    func resolve(_ candidate: DuplicateCandidate, as resolution: DuplicateResolution) {
        resolutions[candidate.id] = resolution
        Haptics.light()
    }

    /// True once every surfaced candidate has a chosen resolution — gates the Save action.
    var allDuplicatesResolved: Bool {
        guard case let .reviewingDuplicates(candidates) = phase else { return false }
        return candidates.allSatisfy { resolutions[$0.id] != nil }
    }

    /// Commit the reviewed capture: apply the chosen resolutions and insert (spec §3.5).
    func confirmResolutions() async {
        guard let prepared = pending else { return }
        phase = .processing
        do {
            let outcome = try await service.finalize(prepared, resolutions: resolutions)
            pending = nil
            resolutions = [:]
            Haptics.success()
            phase = .done(added: outcome.addedTasks, titles: outcome.taskTitles,
                          project: outcome.projectTitle, similar: outcome.similarWarnings)
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        if isListening { stopListening() }
        text = ""
        phase = .editing
        pending = nil
        resolutions = [:]
    }
}
