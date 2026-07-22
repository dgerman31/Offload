import SwiftUI

/// Swipe-right-to-delete for any task row, anywhere — card-based screens (Home, Day) included,
/// not just `List` rows. SwiftUI's native `.swipeActions` only works inside a `List`, so this is
/// a self-contained drag: swipe right to reveal a red Delete button, tap it to confirm, or keep
/// dragging past the threshold to delete outright (the same two ways iOS's own swipe-to-delete
/// works). `.highPriorityGesture` so the swipe still wins over row buttons/taps beneath it.
struct SwipeToDeleteModifier: ViewModifier {
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    private let revealWidth: CGFloat = 84
    private let autoDeleteThreshold: CGFloat = 200

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            deleteButton
            content
                .offset(x: offset)
                .highPriorityGesture(drag)
        }
        .clipped()
    }

    private var deleteButton: some View {
        Button {
            confirmDelete()
        } label: {
            Label("Delete", systemImage: "trash.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
        }
        .background(Color.Offload.red)
        .opacity(offset > 4 ? 1 : 0)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Rightward reveal only — a leftward drag (or one that overshoots back past
                // zero) just snaps closed rather than going negative.
                let proposed = value.translation.width
                offset = max(0, min(proposed, autoDeleteThreshold + 40))
            }
            .onEnded { value in
                if offset > autoDeleteThreshold {
                    confirmDelete()
                } else if value.translation.width > revealWidth / 2 {
                    withAnimation(Motion.quick) { offset = revealWidth }
                } else {
                    withAnimation(Motion.quick) { offset = 0 }
                }
            }
    }

    private func confirmDelete() {
        Haptics.warning()
        withAnimation(Motion.quick) { offset = 400 }
        onDelete()
    }
}

extension View {
    /// Swipe right to reveal Delete (tap to confirm), or drag further to delete outright.
    func swipeToDelete(_ onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(onDelete: onDelete))
    }
}
