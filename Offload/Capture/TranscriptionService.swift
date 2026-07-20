@preconcurrency import Speech
@preconcurrency import AVFoundation

/// On-device speech-to-text for voice capture (spec §2.1).
///
/// Deliberately **not** `@MainActor`: the speech-authorization, recognition, and audio-tap
/// callbacks all fire on background threads. If this type were main-actor-isolated, those
/// closures would inherit main-actor isolation and the Swift runtime would trap
/// (`dispatch_assert_queue` / `swift_task_checkIsolatedSwift`) the moment iOS invoked them
/// off the main thread — which is exactly the crash we hit. Keeping it nonisolated means the
/// callbacks never claim the main actor; UI updates hop back to main via `onTranscript`.
final class TranscriptionService: @unchecked Sendable {

    enum TranscriptionError: Error { case recognizerUnavailable, engineFailed }

    /// Invoked (possibly off the main actor) with the latest partial transcript. The
    /// assigned closure is responsible for hopping to the main actor before touching UI.
    var onTranscript: (@Sendable (String) -> Void)?

    /// Live input level, 0…1, emitted from the audio tap for the waveform. Fires on an audio
    /// thread — hop to the main actor before touching UI state.
    var onLevel: (@Sendable (Double) -> Void)?

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
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isRunning = false

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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true    // nothing leaves the device (spec §1)
        }
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            throw TranscriptionError.engineFailed
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request, weak self] buffer, _ in
            request.append(buffer)
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
            self.request = nil
            throw TranscriptionError.engineFailed
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Nonisolated closure (this type isn't main-actor-isolated), so iOS may call it on
            // any thread without tripping an isolation assertion. onTranscript hops to main itself.
            if let result {
                self?.onTranscript?(result.bestTranscription.formattedString)
            }
            if error != nil || (result?.isFinal ?? false) {
                self?.stop()
            }
        }
        isRunning = true
    }

    func stop() {
        // Idempotent + safe to call from any thread.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
