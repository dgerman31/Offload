import SwiftUI

/// The swipe actions a task row should have.
///
/// SwiftUI only honours `swipeActions` inside a `List`, so this applies to the list-based
/// screens (Projects); the card-based ones (Home, Search, Calendar) offer the same operations
/// through long-press context menus instead. Same actions, same order, same tints either way —
/// the muscle memory holds even though the gesture differs.
///
/// Trailing (the natural, full-swipe side) completes, because that's overwhelmingly the most
/// common action. Leading holds the destructive and deferring ones, which should take
/// deliberate effort.
struct TaskSwipeActions: ViewModifier {
    let task: TaskItem
    var onComplete: () -> Void
    var onDelete: () -> Void
    var onSnooze: ((TaskActions.Snooze) -> Void)?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(action: onComplete) {
                    Label(task.status == "completed" ? "Reopen" : "Done",
                          systemImage: task.status == "completed" ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(task.status == "completed" ? Color.Offload.muted : Color.Offload.green)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                if let onSnooze {
                    Button { onSnooze(.tomorrow) } label: {
                        Label("Tomorrow", systemImage: "sun.horizon.fill")
                    }
                    .tint(Color.Offload.amber)
                }
            }
    }
}

extension View {
    /// Apply the app's standard task swipe actions.
    func taskSwipeActions(
        _ task: TaskItem,
        onComplete: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSnooze: ((TaskActions.Snooze) -> Void)? = nil
    ) -> some View {
        modifier(TaskSwipeActions(task: task, onComplete: onComplete, onDelete: onDelete, onSnooze: onSnooze))
    }
}
