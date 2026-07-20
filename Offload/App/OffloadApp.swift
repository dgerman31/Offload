import SwiftUI

@main
struct OffloadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = ModelAvailability()
    @State private var capture = CaptureCoordinator.shared

    init() {
        BackgroundSynthesis.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(availability)
                .environment(capture)
                .tint(Color.Offload.indigo)
                .themed()   // honour the light/dark preference from Settings
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-check the model (e.g. after enabling Apple Intelligence) and run a
                // cheap opportunistic pattern pass so suggestions feel fresh.
                availability.refresh()
                Task { await PatternService.shared.refresh() }
                Task { await NotificationSync.shared.refresh() }
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
