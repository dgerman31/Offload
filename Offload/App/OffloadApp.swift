import SwiftUI

@main
struct OffloadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = ModelAvailability()
    @State private var capture = CaptureCoordinator.shared

    init() {
        BackgroundSynthesis.register()
        // Register notification actions before any reminder can arrive, so "Mark done" and
        // "In an hour" are available on the very first one.
        MainActor.assumeIsolated {
            NotificationDelegate.shared.register()
            // Wire the Lock Screen's buttons to the real timer. The intents themselves live in
            // `Shared` so the widget extension can compile them, but they run in *this* process —
            // this is the line that gives them something to talk to. Installed in `init` because
            // a `LiveActivityIntent` can wake the app with no scene, before any view exists.
            FocusCommandBus.install { command in
                let timer = FocusTimer.shared
                switch command {
                case .pause:
                    timer.pause()
                case .resume:
                    // One button for both stopped states — paused mid-block, and holding at the
                    // start of a phase that's waiting on you. From a Lock Screen they read the
                    // same ("start it again"), so they behave the same.
                    if timer.session?.awaitingStart == true {
                        timer.startNextPhase()
                    } else {
                        timer.resume()
                    }
                case .skip:
                    timer.skipPhase()
                case .end:
                    timer.end(markingComplete: false)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(availability)
                .environment(capture)
                .tint(Color.Offload.indigoText)
                .themed()   // honour the light/dark preference from Settings
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-check the model (e.g. after enabling Apple Intelligence) and run a
                // cheap opportunistic pattern pass so suggestions feel fresh.
                availability.refresh()
                // Bring the focus timer up to date before anything else. Its clock is a wall-time
                // deadline, so nothing was lost while the app was suspended — but a phase may
                // well have ended in the meantime, and the user should find that already handled
                // rather than watch it happen a second after they look at it.
                FocusTimer.shared.restore()
                FocusTimer.shared.applicationBecameActive()
                // Learn when the day started, then lay down today's routine sessions before
                // anything reads the schedule.
                WakeTracker.recordOpen()
                Task {
                    await RoutineService.shared.materialize()
                    // Any capture whose extraction failed last time — usually because the
                    // on-device model wasn't ready or the network was gone. Both have normally
                    // changed by the next launch, and until this ran those words were saved but
                    // invisible. Before the pattern pass, so recovered tasks are in it.
                    await CaptureRetrySweep.run()
                    await PatternService.shared.refresh()
                    // Once a day, work out what yesterday taught us. Throttled internally, and
                    // last in the chain because nothing on screen is waiting for it — the profile
                    // it writes is read by the *next* plan, not this launch's.
                    await LearningPass.runIfStale()
                    await NotificationSync.shared.refresh()
                }
            case .background:
                BackgroundSynthesis.schedule()
                // Leaving the app is exactly when the schedule must be correct.
                Task { await NotificationSync.shared.refresh() }
            default:
                break
            }
        }
    }
}
