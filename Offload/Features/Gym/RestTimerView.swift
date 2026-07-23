import SwiftUI

/// A between-sets countdown — tap a set's rest time to start it, watch it count down, and get a
/// haptic the instant it hits zero. Deliberately tiny (a sheet, not a full screen): unlike
/// `FocusSession`, resting isn't the point of the workout, just a pause inside it, so this should
/// stay out of the way and dismiss itself the moment it's done being useful.
@MainActor
@Observable
final class RestTimer {
    private(set) var totalSeconds: Int
    private(set) var remaining: Int
    private(set) var finished = false
    private var ticker: Task<Void, Never>?

    init(seconds: Int) {
        totalSeconds = max(1, seconds)
        remaining = totalSeconds
    }

    var progress: Double {
        totalSeconds == 0 ? 0 : Double(totalSeconds - remaining) / Double(totalSeconds)
    }

    var clock: String {
        String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 {
            finished = true
            ticker?.cancel()
        }
    }

    /// Add time without losing what's already elapsed — for "actually, one more minute."
    func addSeconds(_ delta: Int) {
        totalSeconds += delta
        remaining += delta
        if remaining > 0 { finished = false }
        if ticker == nil, !finished { start() }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }
}

extension RestTimerView {
    /// A `.sheet(item:)` needs something `Identifiable`; a bare `Int` (the rest seconds) isn't,
    /// so this is the small wrapper that lets tapping a different exercise's rest time present a
    /// fresh timer rather than being mistaken for "the same sheet, no change."
    struct Config: Identifiable {
        let id = UUID()
        var seconds: Int
        var accent: Color = .Offload.indigo
    }
}

struct RestTimerView: View {
    let seconds: Int
    var accent: Color = .Offload.indigo

    @Environment(\.dismiss) private var dismiss
    @State private var timer: RestTimer

    init(seconds: Int, accent: Color = .Offload.indigo) {
        self.seconds = seconds
        self.accent = accent
        _timer = State(initialValue: RestTimer(seconds: seconds))
    }

    var body: some View {
        VStack(spacing: 28) {
            Text(timer.finished ? "Rest's up" : "Resting")
                .font(.caption).fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(Color.Offload.muted)

            ZStack {
                Circle().stroke(Color.Offload.divider, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0.001, 1 - timer.progress))
                    .stroke(accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: timer.progress)
                Text(timer.clock)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.Offload.text)
            }
            .frame(width: 180, height: 180)
            .sensoryFeedback(.success, trigger: timer.finished) { _, new in new }

            HStack(spacing: 12) {
                Button { timer.addSeconds(15) } label: {
                    Text("+15s")
                        .font(.Offload.taskTitle)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Color.Offload.surface, in: .capsule)
                        .foregroundStyle(Color.Offload.text)
                }
                .buttonStyle(.pressable)

                Button { dismiss() } label: {
                    Text(timer.finished ? "Done" : "Skip")
                        .font(.Offload.taskTitle)
                        .padding(.horizontal, 24).padding(.vertical, 11)
                        .background(accent, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(28)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .task { timer.start() }
        .onDisappear { timer.stop() }
    }
}

#Preview {
    RestTimerView(seconds: 90)
}
