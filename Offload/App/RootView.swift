import SwiftUI

/// The five tabs from spec §5.4. The capture screen presents as a sheet over the
/// current tab whenever the Action Button intent (or the in-app button) fires.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture

    var body: some View {
        @Bindable var capture = capture

        TabView {
            Tab("Home", systemImage: "square.stack.3d.up") { HomeView() }
            Tab("Today", systemImage: "sun.max") { TodayView() }
            Tab("Projects", systemImage: "folder") { ProjectsView() }
            Tab("Search", systemImage: "magnifyingglass") { SearchView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .sheet(isPresented: $capture.isCapturing) {
            CaptureView()
        }
    }
}

#Preview {
    RootView()
        .environment(ModelAvailability())
        .environment(CaptureCoordinator.shared)
}
