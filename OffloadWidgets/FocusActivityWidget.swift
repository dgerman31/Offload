import SwiftUI
import WidgetKit
import ActivityKit

/// The focus timer as it appears on the Lock Screen and in the Dynamic Island.
///
/// The countdown is `Text(timerInterval:)` throughout, never a number this code computes. That
/// distinction is the whole feature: the system re-renders the digits itself, once a second,
/// with the app suspended or not running at all. Anything self-computed would freeze the moment
/// the app stopped — which is exactly the bug this replaced.
///
/// Type is `.rounded` and monospaced-digit rather than the app's Manrope. Two reasons: shipping
/// the font into a second target for one string is a poor trade, and a rounded monospaced face is
/// what a countdown should look like — it's what the system's own timers use, and digits that
/// don't shift width as they tick is the only property that really matters at a glance.
struct FocusActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.phase.label)
                    } icon: {
                        Image(systemName: context.state.phase.symbol)
                    }
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(accent(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BlockDots(completed: context.state.completedBlocks, accent: accent(context))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.taskTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Countdown(state: context.state, size: 34, accent: accent(context))
                        Spacer(minLength: 8)
                        Controls(state: context.state, accent: accent(context))
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(accent(context))
            } compactTrailing: {
                Countdown(state: context.state, size: 13, accent: accent(context))
                    .frame(maxWidth: 54)
            } minimal: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(accent(context))
            }
            .keylineTint(accent(context))
        }
    }

    private func accent(_ context: ActivityViewContext<FocusActivityAttributes>) -> Color {
        Color(hex: context.attributes.accentHex)
    }
}

/// The Lock Screen banner.
private struct LockScreenView: View {
    let context: ActivityViewContext<FocusActivityAttributes>

    private var accent: Color { Color(hex: context.attributes.accentHex) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: context.state.phase.symbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text(context.state.phase.label.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                }
                .foregroundStyle(accent)

                Text(context.attributes.taskTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Countdown(state: context.state, size: 38, accent: .white)

                BlockDots(completed: context.state.completedBlocks, accent: accent)
            }
            Spacer(minLength: 0)
            Controls(state: context.state, accent: accent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// The digits.
///
/// `Text(timerInterval:)` when the clock is moving — the system owns that countdown and keeps it
/// ticking with the app dead. Static text when paused, because a paused timer interval has no
/// representation: it would carry on counting down regardless of what the app thinks.
private struct Countdown: View {
    let state: FocusActivityAttributes.ContentState
    let size: CGFloat
    let accent: Color

    var body: some View {
        Group {
            if let paused = state.pausedRemaining {
                Text(Self.clock(paused))
                    .foregroundStyle(state.awaitingStart ? accent : .white.opacity(0.55))
            } else {
                Text(timerInterval: state.phaseStart...state.phaseEnd, countsDown: true)
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Pomodoro progress — four dots filling toward the long break.
private struct BlockDots: View {
    let completed: Int
    let accent: Color

    private static let perLongBreak = 4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.perLongBreak, id: \.self) { index in
                Circle()
                    .fill(index < completed % Self.perLongBreak || (completed > 0 && completed % Self.perLongBreak == 0)
                          ? accent : Color.white.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
            if completed >= Self.perLongBreak {
                Text("×\(completed / Self.perLongBreak)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
    }
}

/// Pause / resume and the break button, driven by `LiveActivityIntent`s that run in the app's
/// process — so tapping here and tapping inside the app go through the identical code path.
private struct Controls: View {
    let state: FocusActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            if state.isRunning {
                Button(intent: PauseFocusIntent()) {
                    icon("pause.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause")

                // The pomodoro button: end this block early and take the break (or, mid-break,
                // cut it short and get back to it).
                Button(intent: SkipFocusPhaseIntent()) {
                    icon(state.phase.isBreak ? "arrow.uturn.forward" : "cup.and.saucer.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.phase.isBreak ? "Back to work" : "Take a break")
            } else {
                Button(intent: ResumeFocusIntent()) {
                    icon("play.fill", filled: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.awaitingStart ? "Start" : "Resume")
            }
        }
    }

    private func icon(_ name: String, filled: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(filled ? Color.black : .white)
            .frame(width: 42, height: 42)
            .background(filled ? accent : Color.white.opacity(0.16), in: .circle)
    }
}

/// The widget target has no access to the app's design system, so the one colour helper it needs
/// is redeclared here rather than shared — a second target for a four-line initializer would cost
/// more than it saves.
extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
