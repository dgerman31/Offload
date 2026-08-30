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
    ///
    /// Silent under Reduce Motion — see `ScrollAppear`.
    func scrollAppear(scale: CGFloat = 0.94, lift: CGFloat = 14) -> some View {
        modifier(ScrollAppear(scale: scale, lift: lift))
    }

    /// First-load cascade: each card arrives just after the one above it. Cheap to run,
    /// and it's what makes a screen feel composed rather than dumped on screen at once.
    ///
    /// Silent under Reduce Motion — see `AppearIn`.
    func appearIn(_ index: Int, when appeared: Bool, stagger: Double = 0.055) -> some View {
        modifier(AppearIn(index: index, appeared: appeared, stagger: stagger))
    }

    /// Softer variant for dense rows, where a big scale would read as noisy.
    func scrollAppearSubtle() -> some View {
        modifier(ScrollAppear(scale: 0.985, lift: 0, restingOpacity: 0.15))
    }
}

/// Press feedback that makes taps feel physical: a quick spring inward, and a gentle dim.
///
/// Under Reduce Motion the scale is dropped and only the dim remains — the press still
/// acknowledges itself, it just doesn't move. A `ButtonStyle` can't read the environment
/// directly, hence the nested view.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        PressedLabel(configuration: configuration, scale: scale)
    }

    /// Deliberately *not* called `Body`: `ButtonStyle` has an associated type of that name, so a
    /// nested `Body` is read as the protocol's witness rather than a helper view — and a private
    /// witness can't satisfy an internal protocol, which is the error that produced.
    private struct PressedLabel: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: Configuration
        let scale: CGFloat

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Motion.respecting(reduceMotion, Motion.quick), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    static func pressable(scale: CGFloat) -> PressableButtonStyle { PressableButtonStyle(scale: scale) }
}

// MARK: Reduce Motion

/// The app's entrance choreography, made optional.
///
/// Every one of these ran unconditionally: 51 staggered card entrances and two scroll transitions,
/// on every screen, for everyone. A person who has asked iOS to stop moving things — often because
/// motion makes them ill — got all of it anyway. The system adapts its *own* materials to Reduce
/// Motion automatically; hand-rolled `scrollTransition` and stagger it cannot see, so this is ours
/// to honour.
///
/// The rule here is "arrive, don't travel": under Reduce Motion content still fades, because a
/// cross-fade is not vestibular motion and a hard pop is worse for everyone. What stops is the
/// movement — the lift, the scale, and the cascade's delay.
struct AppearIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let appeared: Bool
    var stagger: Double = 0.055

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (appeared ? 0 : 18))
            .animation(animation, value: appeared)
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : Motion.settle.delay(Double(index) * stagger)
    }
}

/// Scroll-driven entrance, likewise optional. Under Reduce Motion the content simply sits there:
/// a `scrollTransition` that scales and offsets as you scroll is continuous motion tied to the
/// finger, which is exactly what the setting exists to stop.
struct ScrollAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.94
    var lift: CGFloat = 14
    /// What the content fades to when it's outside the viewport. The subtle variant dims rather
    /// than disappearing.
    var restingOpacity: Double = 0

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : restingOpacity)
                    .scaleEffect(phase.isIdentity ? 1 : scale, anchor: .center)
                    .offset(y: phase.isIdentity ? 0 : (phase.value < 0 ? -lift : lift))
            }
        }
    }
}

extension Motion {
    /// A spring, or nothing, depending on the person using the app. For `withAnimation` call sites,
    /// which cannot read the environment themselves — read `\.accessibilityReduceMotion` in the
    /// view and pass it in.
    ///
    /// Deliberately returns a short fade rather than `nil`: an instant state change reads as a
    /// glitch, and Reduce Motion asks for less *movement*, not less feedback.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : animation
    }
}

// MARK: Touch targets

extension View {
    /// Guarantee Apple's 44×44pt minimum touch target without changing how big the thing *looks*.
    ///
    /// Icon buttons are drawn small on purpose — a 20pt glyph in a row shouldn't be a 44pt glyph.
    /// But the area that *responds* has to be 44pt or it's a coin toss whether a tap lands, which
    /// is worse for anyone with imprecise aim and worse for everyone in a moving car. The frame
    /// grows, the artwork doesn't, and `contentShape` makes the whole frame tappable rather than
    /// just the opaque pixels of the glyph.
    func hitTarget(_ minimum: CGFloat = 44) -> some View {
        frame(minWidth: minimum, minHeight: minimum)
            .contentShape(Rectangle())
    }
}
