import SwiftUI

/// Swipe-right-to-delete for any task row, anywhere — card-based screens (Home, Day) included,
/// not just `List` rows. SwiftUI's native `.swipeActions` only works inside a `List`, so this is
/// a self-contained drag: swipe right to reveal a red Delete rail, tap it to confirm, or keep
/// dragging past the threshold to delete outright (the same two ways iOS's own swipe-to-delete
/// works).
///
/// Two things that matter for this to sit inside a normal scrolling screen without getting in the
/// way: it only ever reacts to a drag that's clearly more horizontal than vertical (a vertical
/// scroll is ignored completely, at the gesture-recognition level — not just "decides not to act"
/// on it, which would still have blocked the scroll), and it uses `.simultaneousGesture` rather
/// than claiming exclusive priority, so the scroll view underneath keeps receiving and acting on
/// the same touch the entire time regardless of what this view does with it.
///
/// Tuned to match native iOS's feel, not just its two end-states: the red rail's width tracks the
/// drag distance directly (no gap between it and the sliding content), the icon fades in smoothly
/// with the drag instead of popping in or sitting there at rest, dragging past the delete
/// threshold rubber-bands rather than hard-stopping, and the row animates fully off-screen before
/// the underlying data is actually removed, so the visual and the mutation never race. The release
/// itself inherits the drag's actual velocity — a fast flick snaps or deletes with real authority,
/// a slow drag settles gently, instead of every release using the identical canned motion.
struct SwipeToDeleteModifier: ViewModifier {
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var crossedThreshold = false
    @State private var isDeleting = false
    @State private var rowWidth: CGFloat = 400
    private let revealWidth: CGFloat = 84
    private let autoDeleteThreshold: CGFloat = 200
    /// How much a drag past the threshold still moves things, as a fraction of the raw distance —
    /// real resistance instead of an instant hard clamp.
    private let rubberBandFactor: CGFloat = 0.3

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            deleteRail
            content
                .offset(x: offset)
                .simultaneousGesture(drag)
        }
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { rowWidth = proxy.size.width }
            }
        )
        // Declarative haptics tied to the exact moments they mean something: a light tap right
        // as the drag crosses into "let go and this deletes," and a firmer one when it commits.
        .sensoryFeedback(.impact(weight: .light), trigger: crossedThreshold) { _, new in new }
        .sensoryFeedback(.warning, trigger: isDeleting) { _, new in new }
    }

    /// The red background grows with the drag (so it always fills exactly what's revealed, never
    /// leaving a gap), while the icon itself stays pinned near the leading edge at its natural
    /// width — the same way a native swipe action's rail can stretch further than its button.
    /// Both fade in continuously with the drag so nothing is visible at all at rest.
    private var deleteRail: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.Offload.red)
                .frame(width: max(0, offset))
                .frame(maxHeight: .infinity)
            Button(action: { confirmDelete() }) {
                Label("Delete", systemImage: "trash.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        // Fully transparent exactly at rest; fades in over the first ~24pt of drag, well before
        // anything is actionable, so there's never a moment of an icon floating with no motion.
        .opacity(min(1, offset / 24))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // A vertical scroll must never be mistaken for a swipe attempt — bail out
                // entirely (not just "don't act"; `offset` genuinely never moves) whenever the
                // drag isn't clearly horizontal-dominant yet.
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    offset = 0
                    crossedThreshold = false
                    return
                }
                let raw = value.translation.width
                offset = raw <= autoDeleteThreshold
                    ? max(0, raw)
                    : autoDeleteThreshold + (raw - autoDeleteThreshold) * rubberBandFactor

                // Flips right as you cross into "let go and this deletes" — not only once
                // you've already committed. Re-arms if you drag back below the line. The actual
                // haptic fires declaratively from `.sensoryFeedback`, keyed to this value.
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
                let velocity = value.velocity.width
                if offset > autoDeleteThreshold {
                    confirmDelete(releaseVelocity: velocity)
                } else if value.translation.width > revealWidth / 2 {
                    snap(to: revealWidth, releaseVelocity: velocity)
                } else {
                    snap(to: 0, releaseVelocity: velocity)
                }
            }
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
    /// Swipe right to reveal Delete (tap to confirm), or drag further to delete outright.
    func swipeToDelete(_ onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(onDelete: onDelete))
    }
}
