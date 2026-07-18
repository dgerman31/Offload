import Foundation
import BackgroundTasks

/// BGProcessingTask wiring (spec §2.1 / §3.6): heavier cross-capture passes run
/// opportunistically in the background; results land as dismissible suggestions.
enum BackgroundSynthesis {
    static let taskId = "com.danielgerman.offload.synthesis"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(processing)
        }
    }

    /// Ask for a run no sooner than ~6h out; the system picks the opportune moment.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskId)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()   // keep the chain alive

        // BGTask isn't Sendable; we only touch it to complete it once the pass finishes.
        nonisolated(unsafe) let bgTask = task
        let work = Task { @MainActor in
            await PatternService.shared.refresh()
            bgTask.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            bgTask.setTaskCompleted(success: false)
        }
    }
}
