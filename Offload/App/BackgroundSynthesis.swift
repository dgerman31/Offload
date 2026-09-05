import Foundation
import BackgroundTasks

/// Keeps the Anki bar current while Offload is closed.
///
/// A `BGAppRefreshTask`, not a processing one: this wants a quarter of an hour, where
/// `BackgroundSynthesis` is a "sometime tonight when the phone is idle" budget. The realistic case
/// is you reviewing on the Mac with the phone face-down on the desk — nothing of ours is running,
/// and without this the Lock Screen bar would sit on whatever it said when you last opened the app.
///
/// It **updates** the Live Activity and never starts one. iOS doesn't allow a background start, and
/// that exact mistake is what made the scroll timer's Lock Screen bar never appear — see
/// `AnkiLiveActivity`.
enum AnkiBackgroundRefresh {
    static let taskId = "com.danielgerman.offload.ankirefresh"
    /// The floor iOS enforces anyway; asking for less just gets rounded up.
    static let interval: TimeInterval = 15 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // keep the chain alive

        nonisolated(unsafe) let bgTask = task
        let work = Task { @MainActor in
            let bridge = AnkiBridge.shared
            let refreshed = await bridge.refresh(force: true)
            await AnkiLiveActivity.sync(bridge.current(),
                                        enabled: bridge.showsLiveActivity,
                                        canStart: false)   // background: update only, never start
            bgTask.setTaskCompleted(success: refreshed)
        }
        task.expirationHandler = {
            work.cancel()
            bgTask.setTaskCompleted(success: false)
        }
    }
}

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
            // The learning pass rides along here rather than getting its own background task:
            // it wants exactly the same "sometime when the phone is idle" treatment, and a
            // second BGProcessingTask would compete with this one for the same budget.
            await LearningPass.run()
            bgTask.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            bgTask.setTaskCompleted(success: false)
        }
    }
}
