import SwiftUI

/// The four tabs. Home is the light "what needs me" view; the day's actual schedule (events +
/// timed tasks) lives in its own Day tab, which replaced the old month-grid Calendar. Projects
/// left the tab bar to declutter — it's now reached from a card on Home. The capture screen
/// presents as a sheet over the current tab whenever the Action Button intent (or the in-app
/// button) fires.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @AppStorage(OnboardingView.completedKey) private var onboarded = false

    var body: some View {
        @Bindable var capture = capture

        Group {
            if onboarded {
                tabs
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $capture.isCapturing) {
            CaptureView()
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Home", systemImage: "square.stack.3d.up") { HomeView() }
            Tab("Day", systemImage: "calendar.day.timeline.left") { DayView() }
            Tab("Search", systemImage: "magnifyingglass") { SearchView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}

#Preview {
    RootView()
        .environment(ModelAvailability())
        .environment(CaptureCoordinator.shared)
}
