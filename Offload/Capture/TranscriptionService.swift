@preconcurrency import Speech
@preconcurrency import AVFoundation
import Foundation

/// On-device speech-to-text for voice capture (spec §2.1).
///
/// ### Long dictation, and why it used to reset
///
/// `SFSpeechRecognizer` does not do long-form audio. A single recognition request is finalised by
/// the system after roughly a minute — sooner if you pause — and every request's
/// `bestTranscription.formattedString` starts again from empty. Naively piped into the UI, that
/// reads as *the app wiping what you just said the moment you talk for a while*, which is the worst
/// possible failure for a capture app: the longer and more valuable the thought, the more certainly
/// it's lost.
///
/// So a session here is not one recognition request. It's a **chain** of them over one continuously
/// running audio engine: when the system finalises a segment its text is committed, a fresh request
/// is swapped in without touching the mic, and what's published is always *everything so far*. From
/// the outside there is no limit and no seam.
///
/// The audio engine deliberately keeps running across the swap — tearing it down and restarting it
/// would drop the audio spoken during the gap, which is exactly the word you were in the middle of.
///
/// Deliberately **not** `@MainActor`: the speech-authorization, recognition, and audio-tap
/// callbacks all fire on background threads. If this type were main-actor-isolated, those
/// closures would inherit main-actor isolation and the Swift runtime would trap
/// (`dispatch_assert_queue` / `swift_task_checkIsolatedSwift`) the moment iOS invoked them
/// off the main thread — which is exactly the crash we hit. Keeping it nonisolated means the
/// callbacks never claim the main actor; UI updates hop back to main via `onTranscript`.
///
/// Because it *isn't* isolated, the session state (`request`, `task`, `isRunning`) is guarded by
/// `lock` instead. That's not theoretical tidying: `stop()` is genuinely called from two threads —
/// the recognition callback on a Speech framework thread when a result is final or errors, and the
/// main actor when the user taps stop — and the two used to race on releasing `request`/`task`,
/// which is an over-release crash rather than merely stale state.
final class TranscriptionService: @unchecked Sendable {

    enum TranscriptionError: Error { case recognizerUnavailable, engineFailed }

    /// Invoked (possibly off the main actor) with the latest partial transcript. The
    /// assigned closure is responsible for hopping to the main actor before touching UI.
    var onTranscript: (@Sendable (String) -> Void)?

    /// Live input level, 0…1, emitted from the audio tap for the waveform. Fires on an audio
    /// thread — hop to the main actor before touching UI state.
    var onLevel: (@Sendable (Double) -> Void)?

    /// Invoked (off the main actor) when the session ends **on its own** with a real error —
    /// the recognizer failing partway through, most commonly because Low Power Mode has made
    /// on-device recognition unavailable. This is what lets a caller learn the mic died mid-
    /// stream even though nothing called `stop()` — without it, `isListening`-style state on
    /// the caller side never finds out and the UI looks live over a dead session.
    var onSessionEnded: (@Sendable (Error) -> Void)?

    /// RMS of the buffer mapped onto a rough 0…1 scale. Returns nil for non-float formats
    /// rather than guessing.
    nonisolated static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Speech sits low in linear terms; map through dB for a scale that feels right.
        let db = 20 * log10(max(rms, 0.000_001))
        let normalized = (Double(db) + 50) / 50      // -50 dB → 0, 0 dB → 1
        return min(1, max(0, normalized))
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()

    /// Guards the three properties below — and nothing else. Never held across a call that can
    /// re-enter (`engine.stop()`, `task.cancel()`, which can synchronously deliver the final
    /// recognition callback, which calls `stop()`); `NSLock` isn't recursive, so that would
    /// deadlock the mic instead of racing it.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?    // guarded by `lock`
    private var task: SFSpeechRecognitionTask?                     // guarded by `lock`
    private var running = false                                    // guarded by `lock`
    /// Everything finalised by earlier segments of this session. What the caller sees is always
    /// this plus the segment in progress.
    private var committed = ""                                     // guarded by `lock`
    /// True from `start()` until an explicit `stop()`. It's what tells a segment ending on its own
    /// to chain into the next one rather than end the session.
    private var wantsListening = false                             // guarded by `lock`
    /// When the current segment's recognition request was created, so a segment that dies
    /// immediately can be told apart from one that ran its natural length.
    private var segmentStartedAt = Date()                          // guarded by `lock`
    /// Consecutive segments that failed instantly and produced nothing. Silence doesn't count —
    /// a silent segment still runs its full length before the system finalises it — so this only
    /// climbs when recognition is genuinely broken, and it's what stops a dead recognizer being
    /// restarted forever.
    private var emptyRestarts = 0                                  // guarded by `lock`

    /// A segment shorter than this that produced no text didn't hear silence, it failed.
    private static let brokenSegmentSeconds: TimeInterval = 2
    private static let maxEmptyRestarts = 3

    /// Join two pieces of transcript with exactly one space, ignoring empties. Pure and static so
    /// the seam between segments is testable — it's the one place a dropped or doubled space would
    /// show up in the user's own words.
    nonisolated static func join(_ existing: String, _ addition: String) -> String {
        let left = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// Whether a recognition session is live right now.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Ask for speech + microphone permission. Returns true only if both are granted.
    /// (Callbacks fire on a background queue — safe now that we're not main-actor-isolated.)
    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw TranscriptionError.recognizerUnavailable }

        stop()   // never double-install a tap

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Everything below works on locals and only publishes into the guarded properties once the
        // session is actually live, so a failed start can't leave a half-installed session visible
        // to `stop()`.
        let request = makeRequest()

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriptionError.engineFailed
        }
        // Note it does **not** capture the request. The request is swapped out every time a segment
        // is finalised, and a tap holding the original would spend the rest of the session feeding
        // audio to a dead one — the mic would look live and nothing would ever be transcribed again.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.appendToCurrentRequest(buffer)
            // Cheap RMS off the same buffer we're already handed — drives the live waveform so
            // silence actually looks like silence.
            if let level = Self.normalizedLevel(buffer) {
                self?.onLevel?(level)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw TranscriptionError.engineFailed
        }

        lock.lock()
        running = true
        wantsListening = true
        committed = ""
        emptyRestarts = 0
        lock.unlock()

        beginSegment(with: request)
    }

    /// Hand the current audio to whichever request is live right now.
    private func appendToCurrentRequest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    /// A fresh recognition request over the already-running audio engine.
    ///
    /// Publishing the request and marking the segment live happens *before* the task is created:
    /// that callback can fire before `recognitionTask` even returns, and it has to find a session
    /// it can act on.
    private func beginSegment(with request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.request = request
        segmentStartedAt = Date()
        let live = running
        lock.unlock()

        guard live, let recognizer else { return }

        let recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Nonisolated closure (this type isn't main-actor-isolated), so iOS may call it on
            // any thread without tripping an isolation assertion. onTranscript hops to main itself.
            guard let self else { return }
            if let error {
                self.segmentEnded(text: result?.bestTranscription.formattedString, error: error)
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                // The system has closed this segment — usually the ~1 minute ceiling, sometimes a
                // pause. Commit it and chain straight into the next one.
                self.segmentEnded(text: text, error: nil)
            } else {
                self.publish(partial: text)
            }
        }

        lock.lock()
        if running {
            self.task = recognition
            lock.unlock()
        } else {
            // A callback already stopped us in the window above. Don't resurrect a dead session:
            // drop the task rather than storing it over a torn-down state.
            lock.unlock()
            recognition.cancel()
        }
    }

    /// Everything so far, plus the segment in progress.
    private func publish(partial: String) {
        lock.lock()
        let base = committed
        lock.unlock()
        onTranscript?(Self.join(base, partial))
    }

    /// A segment finished — cleanly at the system's ceiling, or with an error. Either way, if the
    /// user hasn't stopped, keep going.
    ///
    /// This is the whole fix. Previously both paths tore the session down, so talking for longer
    /// than about a minute silently ended the mic *and* reset the text.
    private func segmentEnded(text: String?, error: Error?) {
        lock.lock()
        guard wantsListening else {
            lock.unlock()
            return   // an explicit stop() already owns the teardown
        }
        let heard = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ranProperly = Date().timeIntervalSince(segmentStartedAt) >= Self.brokenSegmentSeconds
        if !heard.isEmpty {
            committed = Self.join(committed, heard)
            emptyRestarts = 0
        } else if ranProperly {
            // A silent minute is a person thinking, not a failure.
            emptyRestarts = 0
        } else {
            emptyRestarts += 1
        }
        let base = committed
        let giveUp = emptyRestarts >= Self.maxEmptyRestarts
        let old = (request: request, task: task)
        request = nil
        task = nil
        lock.unlock()

        // Outside the lock: `cancel()` can re-enter through this very callback.
        old.request?.endAudio()
        old.task?.cancel()

        if !base.isEmpty { onTranscript?(base) }

        guard !giveUp else {
            // Recognition is genuinely broken rather than merely finished — restarting again would
            // spin. Hand it back as a session failure, with whatever was heard already published.
            stop()
            onSessionEnded?(error ?? TranscriptionError.recognizerUnavailable)
            return
        }

        beginSegment(with: makeRequest())
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true    // nothing leaves the device (spec §1)
        }
        return request
    }

    /// Tear the session down. Idempotent, and safe from any thread: the state is claimed under
    /// `lock` — so exactly one caller ever owns (and releases) the request and task, however many
    /// threads call this at once — while the framework teardown itself runs outside the lock,
    /// since `cancel()` can re-enter through the recognition callback.
    func stop() {
        lock.lock()
        let request = self.request
        let task = self.task
        self.request = nil
        self.task = nil
        running = false
        // Cleared here and nowhere else: this is the one place a session genuinely ends, so it's
        // the one place the accumulated transcript should stop being the truth.
        wantsListening = false
        committed = ""
        emptyRestarts = 0
        lock.unlock()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

}
