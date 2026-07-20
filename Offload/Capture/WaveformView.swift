import SwiftUI

/// A live waveform while dictating.
///
/// A static "Listening…" label leaves you unsure whether the mic is actually hearing you —
/// which, on the app's single most important screen, is a bad place for doubt. Bars that move
/// with your voice make it obvious, and make speaking feel like it's landing somewhere.
///
/// Driven by the recognizer's audio level rather than a canned animation, so silence looks
/// like silence.
struct WaveformView: View {
    /// 0…1 input level.
    var level: Double
    var tint: Color = Color.Offload.teal
    var barCount = 5

    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: height(for: index, at: t))
                }
            }
            .animation(.linear(duration: 0.05), value: level)
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    /// Each bar runs on its own offset sine so the group ripples instead of pulsing as one
    /// block; amplitude follows the real input level, with a small floor so it never looks dead.
    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let offset = Double(index) * 0.7
        let wave = (sin(time * 6 + offset) + 1) / 2          // 0…1
        let amplitude = max(0.12, min(1.0, level))
        return 5 + CGFloat(wave * amplitude * 17)
    }
}
