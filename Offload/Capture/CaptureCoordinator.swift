import SwiftUI

/// App-wide coordinator that the Action Button intent talks to. When the intent
/// fires (`openAppWhenRun`), it foregrounds the app and calls `beginCapture()`,
/// which flips `isCapturing` so the capture screen presents over whatever tab is
/// showing. (Recording/transcription is wired up in a later increment.)
@MainActor
@Observable
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    /// Drives presentation of the capture sheet.
    var isCapturing = false

    /// One-shot request that the next capture session should start listening immediately
    /// (spec §2.3: the Action Button opens straight into recording). Set by `beginCapture`,
    /// consumed exactly once by the capture view, then cleared — so a later in-app tap
    /// (HomeView) re-presents the sheet typing-first rather than repeating a stale request.
    private(set) var autoListenRequested = false

    private init() {}

    /// - Parameter autoListen: pass `true` from the Action Button path so the sheet opens
    ///   already recording; in-app taps keep the default (`false`, typing-first).
    func beginCapture(autoListen: Bool = false) {
        autoListenRequested = autoListen
        isCapturing = true
    }

    /// Read-and-clear the one-shot auto-listen request. Returns `true` at most once per
    /// `beginCapture(autoListen: true)`.
    func consumeAutoListen() -> Bool {
        defer { autoListenRequested = false }
        return autoListenRequested
    }

    func endCapture() {
        isCapturing = false
        autoListenRequested = false
    }
}
