import SwiftUI
import WidgetKit
import ActivityKit

/// Today's Anki queue on the Lock Screen and in the Dynamic Island, until it's empty.
///
/// A bar and two numbers. Deliberately no timer and nothing self-computed: unlike the focus
/// countdown, these figures only change when Offload fetches a new snapshot, so anything that
/// animated here would be pretending. What it does instead is say how old it is whenever that's
/// more than a couple of minutes — a bar that looked live over half-hour-old numbers would be worse
/// than one that admits its age.
struct AnkiActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AnkiActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Anki", systemImage: "rectangle.on.rectangle.angled")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.remaining) left")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Bar(progress: context.state.progress)
                        Text(Self.detail(context.state))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            } compactLeading: {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                Text("\(context.state.remaining)")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Text("\(context.state.remaining)")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Self.accent)
            }
            .keylineTint(Self.accent)
        }
    }

    /// The app's teal, hardcoded — the design system isn't compiled into this target and shipping it
    /// here for one colour would be a poor trade.
    static let accent = Color(red: 0x16 / 255, green: 0xA9 / 255, blue: 0xA3 / 255)

    static func detail(_ state: AnkiActivityAttributes.ContentState) -> String {
        var parts = ["\(state.done) of \(state.total) done"]
        if state.minutesLeft > 0 { parts.append("≈ \(state.minutesLeft) min") }
        if state.newRemaining > 0 { parts.append("\(state.newRemaining) new") }
        return parts.joined(separator: " · ")
    }

    /// How old the figures are, said out loud once it's worth knowing.
    static func age(_ updatedAt: Date, now: Date = Date()) -> String? {
        let seconds = now.timeIntervalSince(updatedAt)
        guard seconds > 180 else { return nil }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    private struct Bar: View {
        let progress: Double

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(AnkiActivityWidget.accent)
                        .frame(width: max(4, proxy.size.width * progress))
                }
            }
            .frame(height: 7)
        }
    }

    private struct LockScreenView: View {
        let context: ActivityViewContext<AnkiActivityAttributes>

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(context.attributes.deck, systemImage: "rectangle.on.rectangle.angled")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(AnkiActivityWidget.accent)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(context.state.remaining) left")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Bar(progress: context.state.progress)
                HStack(spacing: 6) {
                    Text(AnkiActivityWidget.detail(context.state))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let age = AnkiActivityWidget.age(context.state.updatedAt) {
                        Text(age)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
