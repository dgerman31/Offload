@preconcurrency import Speech
@preconcurrency import AVFoundation

/// On-device speech-to-text for voice capture (spec §2.1). Uses `SFSpeechRecognizer` in
/// on-device mode with a live audio tap; partial results stream to `onTranscript`.
///
/// (The spec lists iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` as the primary engine and
/// `SFSpeechRecognizer` on-device as the fallback. We ship the reliable fallback first and
/// can swap in `SpeechAnalyzer` behind this same interface later.)
///
/// The legacy audio/speech APIs aren't Sendable-annotated, hence the `@preconcurrency`
/// imports; all UI-facing state hops back to the main actor.
@MainActor
final class TranscriptionService {

    enum TranscriptionError: Error { case recognizerUnavailable, engineFailed }

    /// Called on the main actor with the latest partial transcript.
    var onTranscript: (@MainActor (String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isRunning = false

    /// Ask for speech + microphone permission. Returns true only if both are granted.
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

        // Configure the audio session for measurement-quality recording.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true    // nothing leaves the device (spec §1)
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do { try engine.start() } catch { throw TranscriptionError.engineFailed }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Runs off the main actor — hop back for any state we touch.
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor [weak self] in self?.onTranscript?(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor [weak self] in self?.stop() }
            }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
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
