import SwiftUI
import UIKit

/// A pan that only ever begins if the finger is genuinely moving along its axis.
///
/// ### The problem this solves
///
/// Apple's apps never seem confused about whether you're scrolling, swiping a row, or tapping it.
/// That isn't polish — it's a specific mechanism, and SwiftUI's `DragGesture` doesn't have it.
///
/// A `DragGesture(minimumDistance:)` activates as soon as the finger travels that far in **any**
/// direction, and only then can you look at the translation and decide it was really a scroll. By
/// that point the gesture has already begun and is already competing with the scroll view for the
/// touch. The result is the thing you feel as an app "not knowing what you meant": a scroll that
/// stutters because a row briefly thought it was being swiped, or a swipe that doesn't take
/// because the scroll view won the argument.
///
/// UIKit resolves this *before* anything begins. Every recognizer gets asked
/// `gestureRecognizerShouldBegin`, and a recognizer that answers `false` fails instantly and
/// silently — the scroll view then owns the touch outright, with nothing to compete with. That's
/// how `UITableView`'s swipe actions coexist with scrolling: the swipe recognizer inspects the
/// initial *velocity* and declines unless it's mostly horizontal. Velocity, not translation,
/// because at the moment of the decision the finger has barely moved — its direction of travel is
/// the only real signal available.
///
/// `UIGestureRecognizerRepresentable` (iOS 18+) is what makes that reachable from SwiftUI: a real
/// `UIPanGestureRecognizer`, with a real delegate, participating in the same arbitration as
/// everything else on screen. This is not a workaround for SwiftUI — it's the actual system.
struct DirectionalPan: UIGestureRecognizerRepresentable {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    /// Translation while the pan is live, in points.
    var onChange: (CGSize) -> Void
    /// Final translation and release velocity, in points and points/second.
    var onEnd: (CGSize, CGSize) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        let size = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .began, .changed:
            onChange(size)
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: recognizer.view)
            onEnd(size, CGSize(width: velocity.x, height: velocity.y))
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(axis: axis)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let axis: Axis
        init(axis: Axis) { self.axis = axis }

        /// The whole point. Decline the touch outright when it isn't ours, so the scroll view
        /// gets it cleanly instead of winning a fight.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // A dead-straight tap has zero velocity in both axes and isn't a pan at all; let the
            // recognizer begin and simply produce no movement, so a tap still reaches the row.
            guard velocity != .zero else { return true }
            return axis == .horizontal
                ? abs(velocity.x) > abs(velocity.y)
                : abs(velocity.y) > abs(velocity.x)
        }
    }
}
