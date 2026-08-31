import SwiftUI

/// The shared vocabulary of the four day-phase screens.
///
/// The screens are meant to feel like four faces of one object rather than four separate designs,
/// so the pieces they're built from live here: the same eyebrow, the same one enormous line, the
/// same single action at the bottom. What changes between them is the *content* and the wash —
/// never the grammar.
///
/// ### Why the drama isn't in the colours
///
/// The obvious way to make four dramatically different screens is four dramatically different
/// palettes — invert to near-black at night, and so on. That fights the system on every axis the
/// HIG cares about: it breaks the person's light/dark choice, it needs the navigation bar's
/// colour scheme overridden to stay legible, and Liquid Glass in the bars is sampling a background
/// the app has taken over. So the palette stays exactly what it is, and the drama comes from
/// layout instead — one idea per screen, type at four times its usual size, and a great deal of
/// nothing. That's also simply the better version: an empty screen with one sentence on it is more
/// arresting than a coloured one with six cards.
extension DayPhase {
    /// The one accent the screen is allowed. Everything else is text, muted text, or background.
    var tint: Color {
        switch self {
        case .morning: return Color.Offload.amber
        case .midday:  return Color.Offload.teal
        case .evening: return Color.Offload.indigoText
        case .night:   return Color.Offload.indigoText
        }
    }

    /// How strongly the wash reads. Midday is the faintest on purpose — it's the screen you're
    /// meant to be working in front of, not looking at.
    private var washStrength: Double {
        switch self {
        case .morning: return 0.18
        case .midday:  return 0.09
        case .evening: return 0.20
        case .night:   return 0.26
        }
    }

    /// A single wash falling from the top edge, over the app's normal ground. Full-bleed, no card,
    /// no border — the screen is the surface.
    var wash: some View {
        ZStack {
            Color.Offload.background
            LinearGradient(colors: [tint.opacity(washStrength), .clear],
                           startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// The top of a phase screen: a small label saying what this is, one large line, and at most one
/// supporting sentence. Never more — the moment a second idea appears the screen stops being a
/// phase screen and starts being a dashboard again.
struct PhaseHeadline: View {
    var eyebrow: String?
    var title: String
    var subtitle: String?
    var tint: Color = Color.Offload.muted

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(tint)
            }
            Text(title)
                // Scales with Dynamic Type via `relativeTo:`, and shrinks rather than truncating
                // when a long task title meets the largest accessibility sizes.
                .font(.Offload.manrope(34, .bold, relativeTo: .largeTitle))
                .foregroundStyle(Color.Offload.text)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one thing this screen wants you to do.
///
/// A real `.borderedProminent` button at `.large`, not a hand-rolled capsule: on iOS 26 the system
/// button is the thing that picks up the current material and control styling for free, and every
/// hand-rolled equivalent in the app is a small commitment to re-drawing it by hand forever.
struct PhasePrimaryButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Color.Offload.indigo
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .font(.Offload.taskTitle)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(tint)
    }
}

/// The quiet alternative under the primary action. Plain text, no border — it should be findable
/// without competing.
struct PhaseSecondaryButton: View {
    let title: String
    var symbol: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .font(.Offload.body)
            .frame(maxWidth: .infinity)
            .hitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Offload.muted)
    }
}

/// The bottom of a phase screen. Pinned with `.safeAreaInset` rather than placed at the end of the
/// content, so the action stays put whether the screen above it is empty or scrolling.
struct PhaseActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) { content }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 10)
    }
}

/// One line of a plan or a list: the time, then the thing. Hairline-separated, never a card.
///
/// Cards are how the rest of the app groups things that belong together; on these screens there's
/// only one group, so a card around it would be drawing a box around the whole screen.
struct PhaseListRow: View {
    var time: String?
    var title: String
    var symbol: String?
    var tint: Color = Color.Offload.muted
    var dimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time ?? "—")
                .font(.Offload.data)
                .monospacedDigit()
                .foregroundStyle(time == nil ? Color.Offload.muted.opacity(0.5) : Color.Offload.muted)
                .frame(width: 58, alignment: .leading)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.Offload.body)
                .foregroundStyle(dimmed ? Color.Offload.muted : Color.Offload.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}
