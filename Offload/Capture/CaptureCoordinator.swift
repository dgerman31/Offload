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

    private init() {}

    func beginCapture() {
        isCapturing = true
    }

    func endCapture() {
        isCapturing = false
    }
}
