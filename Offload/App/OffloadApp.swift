import SwiftUI

@main
struct OffloadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = ModelAvailability()
    @State private var capture = CaptureCoordinator.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(availability)
                .environment(capture)
                .tint(Color.Offload.indigo)
        }
        // Re-check model availability on return to foreground — e.g. after the
        // user enables Apple Intelligence in Settings.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability.refresh() }
        }
    }
}
