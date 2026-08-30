import SwiftUI

/// The full-screen focus timer.
///
/// Deliberately owns **no** state. It reads `FocusTimer.shared` and sends it commands; closing
/// this screen does nothing to the clock, which is the entire point of the rewrite — the old
/// version created its own `FocusSession` per presentation and paused it in `onDisappear`, so
/// leaving the screen (or the app) was the same thing as stopping the timer.
///
/// "Minimize" rather than "Close", and no destructive default: the timer keeps running in the
/// mini bar above the tab bar and on the Lock Screen, and ending it is a separate, deliberate act.
struct FocusSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    private var timer: FocusTimer { FocusTimer.shared }
    private var session: FocusTimer.Session? { timer.session }
    private var tint: Color { Color.Offload.accent(for: session?.category) }

    var body: some View {
        ZStack {
            // Full-bleed calm background — this screen should feel unlike the rest of the app.
            // It shifts on a break, so the phase is legible before you read a word of it.
            LinearGradient(
                colors: timer.phase.isBreak
                    ? [Color(hex: 0x0F2A28), Color(hex: 0x1E5A4C)]
                    : [Color(hex: 0x141735), Color(hex: 0x3A2E7A)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .animation(Motion.standard, value: timer.phase)

            if let session {
                content(session)
            } else {
                // The session ended from the Lock Screen or a notification while this was open.
                VStack(spacing: 12) {
                    Text("Session over")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    Button("Close") { dismiss() }
                        .font(.Offload.taskTitle)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .task { withAnimation(Motion.settle) { appeared = true } }
    }

    private func content(_ session: FocusTimer.Session) -> some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Label(headline, systemImage: timer.phase.symbol)
                    .font(.caption).fontWeight(.semibold)
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.65))
                Text(session.taskTitle)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }

            ring

            blockDots(session)

            controls(session)

            // Only when the system has actually turned them off. A timer that silently doesn't
            // appear on the Lock Screen reads as a broken app; saying so — and where to fix it —
            // costs one line and turns it back into a setting.
            if !FocusLiveActivity.isAvailable {
                Label("Live Activities are off, so this won't show on your Lock Screen. Settings › Offload › Live Activities.",
                      systemImage: "lock.slash")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 32)
            }

            Button("End session") {
                timer.end(markingComplete: false)
                dismiss()
            }
            .font(.Offload.body)
            .foregroundStyle(.white.opacity(0.55))
            .buttonStyle(.pressable)

            Spacer()

            Button {
                dismiss()
            } label: {
                Label("Keep it running", systemImage: "chevron.down")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.pressable)
            .padding(.bottom, 8)
        }
        .appearIn(0, when: appeared)
    }

    private var headline: String {
        guard let session else { return "" }
        if session.awaitingStart { return timer.phase.isBreak ? "Break ready" : "Ready when you are" }
        if session.pausedRemaining != nil { return "Paused" }
        return timer.phase.isBreak ? timer.phase.label.uppercased() : "FOCUSING ON"
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, timer.progress))
                .stroke(
                    LinearGradient(colors: [.white, tint.opacity(0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: timer.progress)

            VStack(spacing: 4) {
                Text(timer.clock)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(timer.isRunning ? "remaining" : "paused")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 250, height: 250)
    }

    /// Four dots per long break, so the pomodoro cadence is visible rather than remembered.
    private func blockDots(_ session: FocusTimer.Session) -> some View {
        let cycle = FocusTimer.blocksPerLongBreak
        let done = session.completedBlocks
        return HStack(spacing: 7) {
            ForEach(0..<cycle, id: \.self) { index in
                Circle()
                    .fill(index < (done % cycle == 0 && done > 0 ? cycle : done % cycle)
                          ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
            if done > 0 {
                Text("\(done) done")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func controls(_ session: FocusTimer.Session) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                if session.awaitingStart {
                    primary(timer.phase.isBreak ? "Start break" : "Back to it", icon: "play.fill") {
                        timer.startNextPhase()
                    }
                } else if timer.isRunning {
                    secondary("Pause", icon: "pause.fill") { timer.pause() }
                    // The pomodoro button. Mid-focus it banks the block and starts the break;
                    // mid-break it cuts the break short.
                    secondary(timer.phase.isBreak ? "Back to it" : "Take a break",
                              icon: timer.phase.isBreak ? "arrow.uturn.forward" : "cup.and.saucer.fill") {
                        timer.skipPhase()
                    }
                } else {
                    primary("Resume", icon: "play.fill") { timer.resume() }
                }
            }

            Button {
                Task { await finish(session) }
            } label: {
                Label("Task is done", systemImage: "checkmark")
                    .font(.Offload.taskTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.white, in: .capsule)
                    .foregroundStyle(Color.Offload.indigoText)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 28)
    }

    private func primary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action(); Haptics.light()
        } label: {
            Label(title, systemImage: icon)
                .font(.Offload.taskTitle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.white.opacity(0.24), in: .capsule)
                .foregroundStyle(.white)
        }
        .buttonStyle(.pressable)
    }

    private func secondary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action(); Haptics.light()
        } label: {
            Label(title, systemImage: icon)
                .font(.Offload.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.white.opacity(0.16), in: .capsule)
                .foregroundStyle(.white)
        }
        .buttonStyle(.pressable)
    }

    /// Finishing the *task* — the one action that records this as work carried through, which is
    /// what lets it count toward learned effort estimates.
    private func finish(_ session: FocusTimer.Session) async {
        let taskId = session.taskId
        timer.end(markingComplete: true)
        if let task = await TaskSessionLog.task(id: taskId) {
            await TaskActions.toggleComplete(task)
        }
        Haptics.success()
        dismiss()
    }
}

/// The timer, condensed to a bar above the tab bar so a running session is always one tap away
/// and never hidden. Without it, minimizing the full screen would make a running timer invisible
/// inside the app — which is the same confusion as it stopping, just quieter.
struct FocusMiniBar: View {
    private var timer: FocusTimer { FocusTimer.shared }

    var body: some View {
        if let session = timer.session {
            let tint = Color.Offload.accent(for: session.category)
            Button {
                timer.isExpanded = true
                Haptics.light()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: timer.phase.symbol)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.taskTitle)
                            .font(.Offload.manrope(13, .bold))
                            .foregroundStyle(Color.Offload.text)
                            .lineLimit(1)
                        Text(timer.phase.isBreak ? timer.phase.label : "Focusing")
                            .font(.system(.caption2))
                            .foregroundStyle(Color.Offload.muted)
                    }
                    Spacer(minLength: 8)
                    Text(timer.clock)
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.Offload.text)
                    Button {
                        timer.isRunning ? timer.pause() : timer.resume()
                        Haptics.light()
                    } label: {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(tint, in: .circle)
                    }
                    .buttonStyle(.pressable(scale: 0.85))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
