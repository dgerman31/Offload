import SwiftUI

/// The five tabs (spec §5.4). Home is the day dashboard — greeting, what needs you, today's
/// merged timeline — so the old separate "Today" tab folded into it; its slot now holds the
/// interactive Calendar. The capture screen presents as a sheet over the current tab whenever
/// the Action Button intent (or the in-app button) fires.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture

    var body: some View {
        @Bindable var capture = capture

        TabView {
            Tab("Home", systemImage: "square.stack.3d.up") { HomeView() }
            Tab("Calendar", systemImage: "calendar") { CalendarView() }
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
