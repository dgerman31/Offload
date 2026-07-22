import SwiftUI

/// Swipe-right-to-delete for any task row, anywhere — card-based screens (Home, Day) included,
/// not just `List` rows. SwiftUI's native `.swipeActions` only works inside a `List`, so this is
/// a self-contained drag: swipe right to reveal a red Delete rail, tap it to confirm, or keep
/// dragging past the threshold to delete outright (the same two ways iOS's own swipe-to-delete
/// works). `.highPriorityGesture` so the swipe still wins over row buttons/taps beneath it.
///
/// Tuned to match native iOS's feel, not just its two end-states: the red rail's width tracks the
/// drag distance directly (no gap between it and the sliding content), a haptic ticks the instant
/// you cross the delete threshold — not only once you've already committed — dragging past that
/// threshold rubber-bands rather than hard-stopping, and the row animates fully off-screen before
/// the underlying data is actually removed, so the visual and the mutation never race.
struct SwipeToDeleteModifier: ViewModifier {
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var crossedThreshold = false
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
                .highPriorityGesture(drag)
        }
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { rowWidth = proxy.size.width }
            }
        )
    }

    /// The red background grows with the drag (so it always fills exactly what's revealed, never
    /// leaving a gap), while the icon itself stays pinned near the leading edge at its natural
    /// width — the same way a native swipe action's rail can stretch further than its button.
    private var deleteRail: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.Offload.red)
                .frame(width: max(0, offset))
                .frame(maxHeight: .infinity)
            Button(action: confirmDelete) {
                Label("Delete", systemImage: "trash.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let raw = value.translation.width
                offset = raw <= autoDeleteThreshold
                    ? max(0, raw)
                    : autoDeleteThreshold + (raw - autoDeleteThreshold) * rubberBandFactor

                // A tick right as you cross into "let go and this deletes" — not only once
                // you've already committed. Re-arms if you drag back below the line.
                if offset > autoDeleteThreshold, !crossedThreshold {
                    crossedThreshold = true
                    Haptics.light()
                } else if offset <= autoDeleteThreshold {
                    crossedThreshold = false
                }
            }
            .onEnded { value in
                crossedThreshold = false
                if offset > autoDeleteThreshold {
                    confirmDelete()
                } else if value.translation.width > revealWidth / 2 {
                    withAnimation(Motion.swipeRelease) { offset = revealWidth }
                } else {
                    withAnimation(Motion.swipeRelease) { offset = 0 }
                }
            }
    }

    /// Slide the row fully clear of the screen, and only remove the underlying data once that
    /// animation has actually finished — the mutation no longer races the visual.
    private func confirmDelete() {
        Haptics.warning()
        withAnimation(Motion.swipeRelease) {
            offset = rowWidth + 80
        } completion: {
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
