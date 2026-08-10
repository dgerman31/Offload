import Foundation
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

    /// Clarifying chips to offer on the success screen, and the tasks they patch. Cleared the
    /// moment the sheet finishes, so they never linger into the next capture.
    var chips: [ClarifyChip] = []
    private var chipTargetIds: [String] = []
    /// Groups already resolved this session (tapping one chip answers its whole question).
    private var resolvedChipGroups: Set<String> = []

    var text = ""
    var phase: Phase = .editing
    var isListening = false
    /// A recoverable problem to show *over* the editor — the mic wouldn't start, permission is
    /// off — as distinct from `Phase.failed`, which takes over the screen and means "extraction
    /// failed after you submitted". Nothing here should cost you the editor or what you've typed.
    var errorBanner: String?
    /// Live mic level, 0…1, for the waveform.
    var inputLevel: Double = 0

    /// Bumped whenever voice ends and the caller should fall back to the keyboard. A failed
    /// `beginAutoListen` already handles this via its return value, but a session that starts
    /// fine and then dies mid-stream (a recognizer error arriving on a background thread, well
    /// after `start()` returned) has no other way to tell the view — the view observes this and
    /// refocuses the text field each time it changes, so a dying mic always lands you somewhere
    /// usable instead of stuck on a dead mic screen.
    var focusTextFieldRequest = 0

    /// A project the model proposed for this capture's tasks but didn't file them under —
    /// offered, not forced, on the success screen. `nil` means there's nothing to offer, or the
    /// offer already got an answer (accept/decline both clear it, so it never re-asks).
    var suggestedProjectTitle: String?
    /// Set once `acceptSuggestedProject()` succeeds, so the offer card can swap to a brief
    /// confirmation instead of just vanishing.
    var assignedProjectConfirmation: String?
    /// An existing project these tasks were filed into under a different spelling than the one
    /// spoken ("jury three" → "Jury 3"). Shown as a statement with an undo, not a question —
    /// the match was confident enough to act on, but quietly rewriting someone's own words into
    /// a name they didn't use is the kind of helpfulness that reads as a bug.
    var mergedProjectTitle: String?
    /// What this capture actually called the project, so undoing the merge can file the tasks
    /// under that name instead.
    private var capturedProjectName: String?
    /// Why the last attempt couldn't be sorted, when it couldn't. Non-nil drives the alert over
    /// the capture box; the words stay in `text` behind it, ready to send again.
    var unavailableMessage: String?
    /// Things this capture said that were already open, so nothing was created for them.
    /// Shown as a result, not a warning — already having it is the good outcome.
    var alreadyOnList: [String] = []

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
    /// (spec §2.3 auto-record). Reuses the same start path as the mic button, so authorization is
    /// still requested. Returns whether the mic actually came up, so the caller can fall back to
    /// the keyboard instead of leaving you on a screen where nothing happened.
    @discardableResult
    func beginAutoListen() async -> Bool {
        guard !isListening else { return true }
        await startListening()
        return isListening
    }

    /// Shared mic-start path: request authorization, then stream the transcript into `text`.
    ///
    /// A mic that won't start is **not** a failed capture. It used to set `phase = .failed`, which
    /// replaces the whole screen with an error that has no text field on it and no route back to
    /// the editor — so "voice is unavailable" became "capture is unavailable", with the typed
    /// fallback the message itself promises nowhere to be found. Now it surfaces as a banner over
    /// a still-usable editor.
    private func startListening() async {
        errorBanner = nil
        guard await transcription.requestAuthorization() else {
            errorBanner = "Microphone or speech access is off — you can still type below."
            focusTextFieldRequest += 1
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
        // Fires (off the main actor) if the session dies on its own after a clean start — a
        // recognizer error, most commonly Low Power Mode making on-device recognition
        // unavailable. Without this, `isListening` never learns the mic already died and the
        // screen looks live over a dead session.
        transcription.onSessionEnded = { [weak self] error in
            Task { @MainActor in self?.handleUnexpectedVoiceEnd(error) }
        }
        do {
            try transcription.start()
            isListening = true
            Haptics.light()
        } catch {
            isListening = false
            Log.capture.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = voiceUnavailableMessage()
            focusTextFieldRequest += 1
        }
    }

    /// The mic started, then died on its own — most commonly a recognizer error caused by Low
    /// Power Mode. Whatever was transcribed so far stays in `text` untouched; we just stop
    /// pretending the session is live and point the user at the keyboard, which always works.
    private func handleUnexpectedVoiceEnd(_ error: Error) {
        guard isListening else { return }
        isListening = false
        inputLevel = 0
        Log.capture.error("voice session ended mid-capture: \(error.localizedDescription, privacy: .public)")
        errorBanner = voiceUnavailableMessage()
        focusTextFieldRequest += 1
    }

    /// One calm, actionable reason voice isn't working right now — never phrased as a failure,
    /// since the text field beneath it always works regardless. Names Low Power Mode
    /// specifically when that's the actual cause: it's the one thing here the user can fix
    /// themselves, unlike "no signal" or "model still warming up".
    private func voiceUnavailableMessage() -> String {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return "Voice is off while Low Power Mode is on — turn it off to dictate, or just type below."
        }
        return "Voice isn't available right now — type below instead."
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
                showDone(outcome)
            } else {
                // Block before saving: hand the candidates to the UI for a per-item choice.
                pending = prepared
                resolutions = [:]
                Haptics.warning()
                phase = .reviewingDuplicates(candidates: prepared.candidates)
            }
        } catch let unavailable as ExtractionUnavailable {
            hold(unavailable)
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Keep the capture in the box and say why it couldn't be sorted.
    ///
    /// Deliberately *not* `.failed`, which takes over the whole screen and offers only a way out:
    /// nothing here is broken and nothing was lost, the AI just couldn't run this minute. Going
    /// back to `.editing` leaves the words exactly where the user left them — `text` is never
    /// cleared on submit — so dismissing the alert lands them on their own sentence, one tap from
    /// trying again.
    private func hold(_ reason: ExtractionUnavailable) {
        phase = .editing
        // A call cancelled because the user navigated away isn't news. Interrupting them to
        // report their own action would be noise, not diagnosis.
        guard !reason.isSilent else { return }
        Haptics.warning()
        unavailableMessage = reason.message
    }

    /// Move to the success screen, stashing any clarifying chips and the tasks they patch.
    private func showDone(_ outcome: CaptureService.Outcome) {
        chips = outcome.chips
        chipTargetIds = outcome.insertedTaskIds
        resolvedChipGroups = []
        suggestedProjectTitle = outcome.suggestedProjectTitle
        assignedProjectConfirmation = nil
        mergedProjectTitle = outcome.filedUnderExistingProject
        capturedProjectName = outcome.capturedProjectName
        alreadyOnList = outcome.alreadyOnList
        phase = .done(added: outcome.addedTasks, titles: outcome.taskTitles,
                      project: outcome.projectTitle, similar: outcome.similarWarnings)
    }

    // MARK: Post-capture project offer

    /// Accept the model's project suggestion: file the just-saved tasks under it (creating the
    /// project if it doesn't exist yet, matched case-insensitively so tapping this twice can't
    /// spawn a duplicate). Never blocks dismissing the sheet — the capture already succeeded
    /// either way, so a failure here is quiet rather than alarming; the tasks stay right where
    /// they already landed.
    func acceptSuggestedProject() async {
        guard let title = suggestedProjectTitle, !chipTargetIds.isEmpty else { return }
        suggestedProjectTitle = nil
        do {
            try await service.assignProject(taskIds: chipTargetIds, title: title)
            Haptics.success()
            assignedProjectConfirmation = title
        } catch {
            // The error kind only. A GRDB error's description carries the failing SQL *and* its
            // bound arguments — here the user's own project title — which must never reach the
            // log at any privacy level.
            Log.capture.error("assignProject failed: \(CaptureService.errorKind(error), privacy: .public)")
        }
    }

    /// Undo an automatic project merge: put these tasks in a project named the way the capture
    /// actually said it. `matchExisting: false` matters — the whole point is to *not* resolve the
    /// spoken name back into the project it was just separated from.
    func undoProjectMerge() async {
        guard let name = capturedProjectName, !chipTargetIds.isEmpty else { return }
        mergedProjectTitle = nil
        capturedProjectName = nil
        do {
            try await service.assignProject(taskIds: chipTargetIds, title: name, matchExisting: false)
            Haptics.light()
        } catch {
            Log.capture.error("Undoing a project merge failed: \(CaptureService.errorKind(error), privacy: .public)")
        }
    }

    /// Decline the offer — quiet, no confirmation, no re-asking. It only reappears on the next
    /// capture that earns one.
    func declineSuggestedProject() {
        suggestedProjectTitle = nil
        Haptics.light()
    }

    /// True while there are refinement chips left to offer — the success screen holds (doesn't
    /// auto-dismiss) so the user has time to tap one.
    var hasChips: Bool { !chips.isEmpty }

    /// Apply a tapped chip to the just-saved tasks, then clear its whole question group (the four
    /// due-date chips answer one question, so one tap resolves them all). No network round-trip.
    func applyChip(_ chip: ClarifyChip) async {
        guard !chipTargetIds.isEmpty else { return }
        Haptics.light()
        await service.applyChip(chip, toTaskIds: chipTargetIds)
        resolvedChipGroups.insert(chip.group)
        chips.removeAll { $0.group == chip.group }
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
            showDone(outcome)
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Leave the failure screen without losing what was typed — `reset()` also dismisses the
    /// sheet, so it can't double as "let me try typing instead".
    func backToEditing() {
        errorBanner = nil
        phase = .editing
    }

    func reset() {
        if isListening { stopListening() }
        text = ""
        errorBanner = nil
        phase = .editing
        pending = nil
        resolutions = [:]
        chips = []
        chipTargetIds = []
        resolvedChipGroups = []
        suggestedProjectTitle = nil
        assignedProjectConfirmation = nil
        mergedProjectTitle = nil
        capturedProjectName = nil
        unavailableMessage = nil
    }
}
