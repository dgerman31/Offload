import SwiftUI

/// A focus timer for a single task. Planning is only half the job — this is the half where
/// the work actually happens. Deliberately spare: one task, one ring, no settings to fiddle
/// with while you're supposed to be concentrating.
///
/// Finishing marks the task done (spawning the next occurrence if it recurs) and banks the
/// minutes, so focused time becomes something you can look back on.
@MainActor
@Observable
final class FocusSession {
    static let totalMinutesKey = "offload.focus.totalMinutes"
    static let sessionCountKey = "offload.focus.sessions"

    private(set) var task: TaskItem?
    private(set) var totalSeconds = 0
    private(set) var remaining = 0
    private(set) var isRunning = false
    private(set) var finished = false

    private var ticker: Task<Void, Never>?

    var progress: Double {
        totalSeconds == 0 ? 0 : Double(totalSeconds - remaining) / Double(totalSeconds)
    }

    /// "24:05"
    var clock: String {
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func begin(task: TaskItem, minutes: Int) {
        self.task = task
        totalSeconds = max(60, minutes * 60)
        remaining = totalSeconds
        finished = false
        resume()
    }

    func resume() {
        guard !isRunning, remaining > 0 else { return }
        isRunning = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning else { return }
                self.tick()
            }
        }
    }

    func pause() {
        isRunning = false
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 {
            isRunning = false
            finished = true
            ticker?.cancel()
            bankMinutes()
            Haptics.success()
        }
    }

    /// Record the time even on an early stop — partial focus still counts.
    func stop() {
        pause()
        bankMinutes()
    }

    private func bankMinutes() {
        let elapsed = (totalSeconds - remaining) / 60
        guard elapsed > 0 else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.totalMinutesKey) + elapsed, forKey: Self.totalMinutesKey)
        defaults.set(defaults.integer(forKey: Self.sessionCountKey) + 1, forKey: Self.sessionCountKey)
    }

    func reset() {
        pause()
        task = nil
        remaining = 0
        totalSeconds = 0
        finished = false
    }
}

struct FocusSessionView: View {
    let task: TaskItem
    var minutes: Int

    @Environment(\.dismiss) private var dismiss
    @State private var session = FocusSession()
    @State private var appeared = false

    private var tint: Color { Color.Offload.accent(for: task.category) }

    var body: some View {
        ZStack {
            // Full-bleed calm background — this screen should feel unlike the rest of the app.
            LinearGradient(
                colors: [Color(hex: 0x141735), Color(hex: 0x3A2E7A)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 34) {
                Spacer()

                VStack(spacing: 10) {
                    Text(session.finished ? "Time's up" : "Focusing on")
                        .font(.caption).fontWeight(.semibold)
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(task.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }

                ring

                HStack(spacing: 16) {
                    if !session.finished {
                        Button {
                            session.isRunning ? session.pause() : session.resume()
                            Haptics.light()
                        } label: {
                            Label(session.isRunning ? "Pause" : "Resume",
                                  systemImage: session.isRunning ? "pause.fill" : "play.fill")
                                .font(.Offload.taskTitle)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(.white.opacity(0.16), in: .capsule)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.pressable)
                    }

                    Button {
                        Task { await finish() }
                    } label: {
                        Label(session.finished ? "Mark done" : "Done early", systemImage: "checkmark")
                            .font(.Offload.taskTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(.white, in: .capsule)
                            .foregroundStyle(Color(hex: 0x2E3B8C))
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.horizontal, 28)

                Button("Stop without finishing") {
                    session.stop()
                    dismiss()
                }
                .font(.Offload.body)
                .foregroundStyle(.white.opacity(0.6))
                .buttonStyle(.pressable)

                Spacer()
            }
            .appearIn(0, when: appeared)
        }
        .task {
            session.begin(task: task, minutes: minutes)
            withAnimation(Motion.settle) { appeared = true }
        }
        .onDisappear { session.pause() }
        .interactiveDismissDisabled(session.isRunning)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, session.progress))
                .stroke(
                    LinearGradient(colors: [.white, tint.opacity(0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: session.progress)

            VStack(spacing: 4) {
                Text(session.clock)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(session.isRunning ? "remaining" : (session.finished ? "complete" : "paused"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 250, height: 250)
    }

    private func finish() async {
        session.stop()
        await TaskActions.toggleComplete(task)
        Haptics.success()
        dismiss()
    }
}
