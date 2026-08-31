import SwiftUI

/// Tracks which single row, app-wide, currently has its Delete rail revealed.
///
/// iOS's own lists (Reminders, Mail, Messages) all hold to one rule: exactly one row is ever
/// open, and it closes the moment you scroll or open another one. A `List` gets that for free;
/// a card-based screen has to coordinate it, and not coordinating it is precisely what leaves a
/// red rail parked on screen after you've moved on — the "it doesn't go away when I let go"
/// report.
@MainActor
@Observable
final class SwipeRevealCoordinator {
    static let shared = SwipeRevealCoordinator()

    /// The id of the row whose Delete rail is showing, if any.
    private(set) var openRowID: String?

    func open(_ id: String) { openRowID = id }
    func closeAll() { openRowID = nil }
    func close(_ id: String) { if openRowID == id { openRowID = nil } }
}

/// Swipe-right-to-delete for any task row, anywhere — card-based screens (Home, Gym, Search)
/// included, not just `List` rows. SwiftUI's native `.swipeActions` only works inside a `List`
/// (`swipeActionsContainer`, which lifts that restriction, is iOS 27), so this is a
/// self-contained drag: swipe right to reveal a red Delete rail, tap it to confirm, or keep
/// dragging past the threshold to delete outright — the same two ways iOS's own swipe works.
///
/// **Living inside a `ScrollView` without breaking it** is the whole design constraint here, and
/// it comes down to two rules learned the hard way:
///
/// 1. `minimumDistance` must stay comfortably *above* the ~10pt a `ScrollView` needs to claim a
///    pan. A `DragGesture(minimumDistance: 0)` recognizes on touch-down, which means it wins the
///    touch before the scroll view ever gets a chance — that single value is what made the Day
///    tab nearly unscrollable wherever a task sat under your finger.
/// 2. `.gesture`, never `.simultaneousGesture`. Sharing a touch sounds like the accommodating
///    choice, but a simultaneous `DragGesture` on a row inside a scroll view stops that scroll
///    view from scrolling — the opposite of the intent.
///
/// Tap-vs-swipe is settled by gesture *composition* rather than by measuring distances by hand:
/// `.exclusively(before:)` runs the tap only if the drag never recognized. One recognizer, one
/// decision, so a completed swipe can't also open the row (which is what a sibling `Button` did).
/// **Why this isn't `.swipeActions`.** SwiftUI only honours `swipeActions` inside a `List`, and
/// these rows live on card surfaces — Home, Search, All Tasks, Gym, a task's steps — which are
/// composed dashboards rather than lists. Putting them in a `List` to get the native gesture would
/// mean taking the list's insets, separators and row chrome, which is the entire visual identity of
/// those screens. The screens that *are* lists use the real thing: see `TaskSwipeActions`.
///
/// What that costs, and what's been paid: a custom gesture is invisible to assistive technology
/// unless you say otherwise, so this exposes Delete and the row's own tap as
/// `accessibilityAction`s. That is the same mechanism `List` uses to surface its swipe actions to
/// VoiceOver.
struct SwipeToDeleteModifier: ViewModifier {
    /// Stable identity for the one-rail-open-at-a-time rule.
    let id: String
    var onDelete: () -> Void
    /// The row's own "open" action. Passed here rather than attached as a separate
    /// `Button`/`.onTapGesture` alongside this modifier: two independent recognizers race on the
    /// same touch, and a `Button`'s built-in tap has no way to know a sibling drag already
    /// decided the touch was a swipe — which is how a completed swipe still opened the detail.
    var onTap: (() -> Void)? = nil

    @State private var offset: CGFloat = 0
    @State private var crossedThreshold = false
    @State private var isDeleting = false
    @State private var rowWidth: CGFloat = 400

    private var coordinator: SwipeRevealCoordinator { .shared }

    private let revealWidth: CGFloat = 84
    private let autoDeleteThreshold: CGFloat = 200
    /// How much a drag past the threshold still moves things, as a fraction of the raw distance —
    /// real resistance instead of an instant hard clamp.
    private let rubberBandFactor: CGFloat = 0.3
    /// Comfortably above the ~10pt a `ScrollView` needs to claim a pan, so scrolling always wins
    /// an ordinary vertical drag and this gesture never even starts. See the type's docs.
    private let minimumSwipeDistance: CGFloat = 20
    /// A flick this fast (points/second) holds the rail open even if it didn't travel far.
    private let flickVelocity: CGFloat = 600

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            deleteRail
            content
                .offset(x: -offset)
                .gesture(swipeOrTap)
                // Disabled while revealed so the row's *other* interactive elements (a
                // completion checkbox, say) can't be triggered mid-swipe.
                .allowsHitTesting(offset == 0)
            if offset > 0 {
                // Tapping the revealed row closes it rather than doing nothing — what tapping a
                // row with open native swipe actions does.
                Color.clear
                    .contentShape(Rectangle())
                    .offset(x: -offset)
                    .onTapGesture { close() }
            }
        }
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { rowWidth = proxy.size.width }
            }
        )
        // Another row opened, or something scrolled: give up the rail immediately.
        .onChange(of: coordinator.openRowID) { _, open in
            if open != id, offset > 0 {
                withAnimation(Motion.snappy) { offset = 0 }
            }
        }
        // Declarative haptics tied to the exact moments they mean something: a light tap right
        // as the drag crosses into "let go and this deletes," and a firmer one when it commits.
        .sensoryFeedback(.impact(weight: .light), trigger: crossedThreshold) { _, new in new }
        .sensoryFeedback(.warning, trigger: isDeleting) { _, new in new }
        // A swipe is a *sighted, motor* gesture. Without this, deleting was simply unavailable to
        // anyone using VoiceOver or Switch Control — not awkward, unavailable, on every card
        // surface in the app. `accessibilityAction` is the supported way to expose a custom
        // gesture's outcome, and it's what `List`'s own `swipeActions` do behind the scenes.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
        .accessibilityAction {
            // The default action — a VoiceOver double-tap — does what tapping the row does.
            onTap?()
        }
        .accessibilityAction(named: Text("Delete")) {
            confirmDelete()
        }
    }

    /// The red background grows with the drag (so it always fills exactly what's revealed, never
    /// leaving a gap), while the icon itself stays pinned near the leading edge at its natural
    /// width — the same way a native swipe action's rail can stretch further than its button.
    /// Both fade in continuously with the drag so nothing is visible at all at rest.
    private var deleteRail: some View {
        ZStack(alignment: .trailing) {
            Rectangle()
                .fill(Color.Offload.red)
                .frame(width: max(0, offset))
                .frame(maxHeight: .infinity)
            Button { confirmDelete() } label: {
                Label("Delete", systemImage: "trash.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        // Fully transparent exactly at rest; fades in over the first ~24pt of drag, well before
        // anything is actionable, so there's never a moment of an icon floating with no motion.
        .opacity(min(1, offset / 24))
        // At rest the row's own content covers this anyway, but an invisible 84pt button sitting
        // under the leading edge of every row is the kind of thing that silently steals a tap
        // meant for a completion circle. Off unless it's actually showing.
        .allowsHitTesting(offset > 0)
    }

    /// One composed gesture that owns both meanings of the touch. `.exclusively(before:)` gives
    /// the tap a turn only when the drag *failed* to recognize (the finger never travelled
    /// `minimumSwipeDistance`), so a swipe and a tap can never both fire from one touch.
    ///
    /// **Trailing edge, i.e. swipe left.** This used to reveal on the leading edge, which is
    /// backwards from every list in iOS — Mail, Messages, Reminders and `List`'s own
    /// `swipeActions` all put destructive actions on the trailing edge. Matching the platform
    /// costs nothing and means muscle memory built in other apps works here.
    private var swipeOrTap: some Gesture {
        DragGesture(minimumDistance: minimumSwipeDistance)
            .onChanged { value in
                // A vertical scroll must never read as a swipe. The minimum distance above
                // already hands ordinary scrolling to the ScrollView before this gesture starts;
                // this is the backstop for a diagonal drag that does start here.
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    if offset != 0 { offset = 0 }
                    crossedThreshold = false
                    return
                }
                let raw = -value.translation.width
                offset = raw <= autoDeleteThreshold
                    ? max(0, raw)
                    : autoDeleteThreshold + (raw - autoDeleteThreshold) * rubberBandFactor

                // Flips right as you cross into "let go and this deletes" — not only once you've
                // already committed. Re-arms if you drag back below the line. The haptic itself
                // fires declaratively from `.sensoryFeedback`, keyed to this value.
                if offset > autoDeleteThreshold, !crossedThreshold {
                    crossedThreshold = true
                } else if offset <= autoDeleteThreshold {
                    crossedThreshold = false
                }
            }
            .onEnded { value in
                crossedThreshold = false
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(Motion.snappy) { offset = 0 }
                    return
                }
                // Points/second the finger was actually moving at release — carried into the
                // snap so a fast flick reads as faster than a slow drag ending at the same spot.
                let velocity = -value.velocity.width
                if offset > autoDeleteThreshold {
                    confirmDelete(releaseVelocity: velocity)
                } else if offset >= revealWidth || velocity > flickVelocity {
                    // Reminders only *holds* the rail open once you've pulled past the button's
                    // full width, or flicked hard enough to clearly mean it. A tentative
                    // half-swipe springs shut instead of latching open.
                    reveal(velocity: velocity)
                } else {
                    snap(to: 0, releaseVelocity: velocity)
                }
            }
            .exclusively(before: TapGesture().onEnded { onTap?() })
    }

    /// Spring to `target`, inheriting the drag's release velocity. SwiftUI's spring velocity is
    /// expressed as a fraction of the distance still to travel per second, so the raw points/sec
    /// value is normalized against how far `offset` still has to move — but when a fast flick
    /// ends very close to `target`, that distance shrinks toward zero and the same velocity
    /// normalizes to a wildly oversized fraction, making the spring overshoot hard and ring for
    /// seconds instead of settling. Clamping keeps a fast flick feeling fast without that blowup.
    private func normalizedVelocity(_ releaseVelocity: CGFloat, distance: CGFloat) -> CGFloat {
        guard distance != 0 else { return 0 }
        return max(-3, min(3, releaseVelocity / distance))
    }

    private func snap(to target: CGFloat, releaseVelocity: CGFloat) {
        let normalized = normalizedVelocity(releaseVelocity, distance: target - offset)
        withAnimation(.interpolatingSpring(duration: 0.3, bounce: 0.15, initialVelocity: normalized)) {
            offset = target
        }
    }

    /// Latch the rail open, claiming the app's single "open row" slot so any other open rail
    /// closes and a scroll can close this one.
    private func reveal(velocity: CGFloat) {
        coordinator.open(id)
        snap(to: revealWidth, releaseVelocity: velocity)
    }

    private func close() {
        coordinator.close(id)
        snap(to: 0, releaseVelocity: 0)
    }

    /// Slide the row fully clear of the screen — inheriting release velocity when there is one
    /// (a drag-triggered delete), or a plain spring when there isn't (tapping the Delete button
    /// directly). The actual deletion fires on a fixed short delay rather than the animation's
    /// own completion callback: an oversized (pre-clamp) velocity could make the spring's
    /// "logically complete" moment arrive seconds late, leaving the row stuck fully red on
    /// screen — visibly wrong, and the exact "trash can never goes away" symptom this exists to
    /// avoid. A fixed delay times the removal to roughly when the slide is visually done, every
    /// time, regardless of how the spring itself behaves.
    private func confirmDelete(releaseVelocity: CGFloat = 0) {
        isDeleting = true
        coordinator.close(id)
        let target = rowWidth + 80
        let normalized = normalizedVelocity(releaseVelocity, distance: target - offset)
        withAnimation(.interpolatingSpring(duration: 0.3, bounce: 0.1, initialVelocity: normalized)) {
            offset = target
        }
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            onDelete()
        }
    }
}

extension View {
    /// Swipe right to reveal Delete (tap to confirm), or drag further to delete outright. Pass
    /// `onTap` for the row's own "open" action instead of attaching a separate `Button`/
    /// `.onTapGesture` alongside this modifier — the two are independent gesture recognizers that
    /// race on the same touch, which is what let a completed swipe still open the row's detail.
    ///
    /// `id` only needs to be stable and unique among rows on screen (a task id is ideal); it's
    /// what enforces "one rail open at a time".
    func swipeToDelete(id: String, onTap: (() -> Void)? = nil, onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(id: id, onDelete: onDelete, onTap: onTap))
    }

    /// Close any revealed Delete rail as soon as the user starts scrolling — what a `List` does
    /// for free, and the reason a rail never sits stranded on screen in Reminders. Attach to the
    /// `ScrollView` on any screen that uses `swipeToDelete`.
    ///
    /// Keyed to `.interacting` (content actually moving) and deliberately *not* `.tracking` (a
    /// finger merely down): tracking fires on every touch, including the touch that lands on the
    /// revealed Delete button, which would close the rail out from under its own tap.
    @MainActor
    func closesSwipeRailsOnScroll() -> some View {
        onScrollPhaseChange { _, phase in
            if phase == .interacting {
                SwipeRevealCoordinator.shared.closeAll()
            }
        }
    }
}
