import SwiftUI
import WidgetKit
import ActivityKit

/// The scroll timer on the Lock Screen and in the Dynamic Island.
///
/// A clock counting **up**, which is the entire idea: the thing a feed takes from you isn't
/// attention, it's the awareness of how long you've been giving it. Putting an honest number
/// somewhere you'll glance without being told off is most of the intervention, and it happens a
/// full minute before the app says a word.
///
/// `Text(_:style: .timer)` throughout, never a number computed here — the system re-renders it
/// once a second with Offload suspended, which it must be, because you're in another app. Anything
/// self-computed would freeze at the value it had when you switched away, which is worse than
/// showing nothing.
///
/// Amber, not red. This is a nudge, not an alarm, and the copy works hard to stay on your side —
/// a red Lock Screen banner would undo that before a word is read.
struct ScrollActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScrollActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Scrolling", systemImage: "hourglass")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(from: context.attributes.startedAt, size: 17)
                }
                DynamicIslandExpandedRegion(.center) {
                    if let task = context.state.task {
                        Text("instead of \(task)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Buttons()
                }
            } compactLeading: {
                Image(systemName: "hourglass")
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                Elapsed(from: context.attributes.startedAt, size: 13)
            } minimal: {
                Image(systemName: "hourglass")
                    .foregroundStyle(Self.accent)
            }
            .keylineTint(Self.accent)
        }
    }

    /// The app's amber, hardcoded rather than imported: the design system isn't compiled into this
    /// target, and shipping it here for one colour would be a poor trade.
    static let accent = Color(red: 0xD4 / 255, green: 0xA9 / 255, blue: 0x59 / 255)

    private struct LockScreenView: View {
        let context: ActivityViewContext<ScrollActivityAttributes>

        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Scrolling", systemImage: "hourglass")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(ScrollActivityWidget.accent)
                    Elapsed(from: context.attributes.startedAt, size: 30)
                    if let task = context.state.task {
                        // The question the feed erased. Not "how long" — "instead of what".
                        Text("instead of \(task)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Buttons()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Counting up from the moment the feed opened.
    private struct Elapsed: View {
        let from: Date
        var size: CGFloat

        var body: some View {
            Text(from, style: .timer)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                // A counting-up timer is naturally wide and grows a digit at ten minutes; without
                // a fixed lane it would shove the buttons about as it ticks.
                .frame(minWidth: size * 3.2, alignment: .leading)
        }
    }

    /// The way out, on the Lock Screen, one tap from wherever you are.
    private struct Buttons: View {
        var body: some View {
            HStack(spacing: 8) {
                Button(intent: SnoozeScrollGuardIntent()) {
                    Text("15m")
                        .font(.system(.caption, weight: .bold))
                        .frame(minWidth: 34)
                }
                .tint(.white.opacity(0.22))
                Button(intent: StopScrollGuardIntent()) {
                    Image(systemName: "checkmark")
                        .font(.system(.caption, weight: .bold))
                }
                .tint(ScrollActivityWidget.accent)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .foregroundStyle(.white)
        }
    }
}
