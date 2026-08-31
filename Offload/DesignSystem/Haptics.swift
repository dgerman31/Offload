import UIKit

/// Centralized haptics (spec §5.7): light on capture-start, success on completion,
/// warning on error. Honors the system Reduce Motion / haptic settings automatically.
///
/// The vocabulary follows iOS's own, where the *weight* of a tap carries meaning. Picking something
/// up is a heavier event than nudging it one notch, and a system that fires the same light tap for
/// both tells your fingers nothing — which is what "lift" and "crossed a gridline" used to feel
/// like on the day grid.
@MainActor
enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Picking something up. Apple's drag lift is a distinct, heavier thump than anything that
    /// happens *during* the drag, which is how you know the thing is now in your hand.
    static func lift() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Crossing a discrete stop — a quarter-hour on the grid, a new insertion point in a list.
    /// The same feedback a picker gives at each detent, because it means the same thing.
    static func detent() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
