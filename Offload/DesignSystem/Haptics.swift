import UIKit

/// Centralized haptics (spec §5.7): light on capture-start, success on completion,
/// warning on error. Honors the system Reduce Motion / haptic settings automatically.
@MainActor
enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
