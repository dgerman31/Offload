import SwiftUI

/// The app's motion vocabulary. Every animation resolves to one of these, so timing feels
/// like a single designed system instead of a pile of ad-hoc springs. Springs only — nothing
/// in the app uses a linear curve, because physical motion is what reads as expensive.
enum Motion {
    /// Standard UI response: snappy, settles clean, never cartoon-bouncy.
    static let standard = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Immediate feedback for taps, toggles, selection.
    static let quick = Animation.spring(response: 0.26, dampingFraction: 0.78)
    /// Content settling into place — rings filling, numbers counting, cards arriving.
    static let settle = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// Page-scale changes, e.g. swapping months.
    static let page = Animation.spring(response: 0.45, dampingFraction: 0.88)
    /// A swipe's release: snapping open/closed, or the final commit-and-clear. Livelier and
    /// faster than the generic tap-feedback `quick` — a released swipe should feel like it has
    /// its own momentum, not the same settle as a button press. Prefer `SwipeToDeleteModifier`'s
    /// own velocity-aware spring where a real release velocity is available; this is the
    /// no-velocity fallback (e.g. a gesture that turned out not to be a swipe after all).
    static let swipeRelease = Animation.spring(response: 0.3, dampingFraction: 0.72)
    /// Apple's modern "snappy" preset — quick with a touch of bounce. For a small, discrete,
    /// tap-triggered interaction that isn't already covered by `quick`/`standard`.
    static let snappy = Animation.snappy(duration: 0.35, extraBounce: 0.05)
    /// Apple's modern "smooth" preset — no overshoot, settles cleanly. For a larger state
    /// transition (paging a week, swapping a visible range) where a bounce would look busy.
    static let smooth = Animation.smooth
}

/// Depth tokens. Premium interfaces read as *layers* — soft, wide shadows doing the work that
/// hairline borders do in cheaper UI. Kept subtle: light mode leans on shadow, dark mode on a
/// faint top-edge highlight, since shadows are nearly invisible against near-black.
enum Elevation {
    case flat, low, medium, high

    var radius: CGFloat {
        switch self {
        case .flat:   return 0
        case .low:    return 10
        case .medium: return 18
        case .high:   return 30
        }
    }

    var yOffset: CGFloat {
        switch self {
        case .flat:   return 0
        case .low:    return 3
        case .medium: return 8
        case .high:   return 14
        }
    }

    var opacity: Double {
        switch self {
        case .flat:   return 0
        case .low:    return 0.06
        case .medium: return 0.10
        case .high:   return 0.16
        }
    }
}

extension View {
    /// Soft layered shadow — the main depth signal.
    func elevated(_ level: Elevation = .low) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.yOffset)
    }

    /// The app's standard panel: generous radius, real surface, soft depth, and a hairline
    /// that only asserts itself in dark mode where shadow alone can't separate the layers.
    func offloadCard(cornerRadius: CGFloat = 20, elevation: Elevation = .low) -> some View {
        self
            .background(Color.Offload.surface, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.Offload.hairline, lineWidth: 0.5)
            )
            .elevated(elevation)
    }

    /// Scroll-driven entrance: content fades, lifts, and scales into place as it reaches the
    /// viewport, then sits perfectly still. This is the single biggest "expensive app" tell.
    func scrollAppear(scale: CGFloat = 0.94, lift: CGFloat = 14) -> some View {
        scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0)
                .scaleEffect(phase.isIdentity ? 1 : scale, anchor: .center)
                .offset(y: phase.isIdentity ? 0 : (phase.value < 0 ? -lift : lift))
        }
    }

    /// First-load cascade: each card arrives just after the one above it. Cheap to run,
    /// and it's what makes a screen feel composed rather than dumped on screen at once.
    func appearIn(_ index: Int, when appeared: Bool, stagger: Double = 0.055) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
            .animation(Motion.settle.delay(Double(index) * stagger), value: appeared)
    }

    /// Softer variant for dense rows, where a big scale would read as noisy.
    func scrollAppearSubtle() -> some View {
        scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.15)
                .scaleEffect(phase.isIdentity ? 1 : 0.985, anchor: .center)
        }
    }
}

/// Press feedback that makes taps feel physical: a quick spring inward, and a gentle dim.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    static func pressable(scale: CGFloat) -> PressableButtonStyle { PressableButtonStyle(scale: scale) }
}
