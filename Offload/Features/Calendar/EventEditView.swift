import SwiftUI
import EventKit
import EventKitUI

/// Presents Apple's native event editor for a real calendar event, so anything on the timeline
/// can be moved, renamed, or deleted right where you see it. Using the system editor is both the
/// most fluid option (full native edit + a Delete button) and the safest — deleting an event on a
/// shared or work calendar is consequential, and Apple's UI owns that confirmation, not us.
///
/// The `EKEventStore` lives on the coordinator so it outlives `makeUIViewController`; the editor
/// holds a weak reference to it and would otherwise lose its backing store mid-edit.
struct EventEditView: UIViewControllerRepresentable {
    /// The EventKit identifier of the event to edit (from `CalendarEvent.id`).
    let eventId: String
    /// Called when the editor is dismissed (saved, cancelled, or deleted) so the caller can refresh.
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = context.coordinator.store
        // If the event can't be resolved (rare — a nil identifier), the editor opens empty and the
        // user can simply cancel; better than crashing or silently doing nothing.
        controller.event = context.coordinator.store.event(withIdentifier: eventId)
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let store = EKEventStore()
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true)
            onFinish()
        }
    }
}
