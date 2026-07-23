import SwiftUI

/// The five tabs, on the real native `TabView`/`Tab` bar — not a hand-rolled one. Native gets us
/// two things a custom bar can't cheaply match: each tab's content and observations stay alive
/// when you switch away (so switching back is instant, not a fresh reload), and on iOS 26 it's
/// automatically rendered in the new glass style with the scroll-adaptive minimizing behavior,
/// for free. Selection is driven by `AppNavigation` so a deep link (a gym session tapped on Home
/// or Day) can switch tabs from outside the bar itself. The capture screen presents as a sheet
/// over whatever tab is showing, from the Action Button or Home's own capture bar — no raised
/// button on the bar itself.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @AppStorage(OnboardingView.completedKey) private var onboarded = false
    private var nav: AppNavigation { AppNavigation.shared }

    var body: some View {
        @Bindable var capture = capture
        @Bindable var nav = nav

        Group {
            if onboarded {
                TabView(selection: $nav.selectedTab) {
                    Tab("Home", systemImage: "square.stack.3d.up", value: RootTab.home) { HomeView() }
                    Tab("Day", systemImage: "calendar.day.timeline.left", value: RootTab.calendar) { DayView() }
                    Tab("Gym", systemImage: "figure.strengthtraining.traditional", value: RootTab.gym) { GymView() }
                    Tab("Study", systemImage: "graduationcap.fill", value: RootTab.study) { StudyView() }
                    Tab("Settings", systemImage: "slider.horizontal.3", value: RootTab.settings) { SettingsView() }
                }
                .tint(Color.Offload.indigo)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $capture.isCapturing) {
            CaptureView()
        }
    }
}

/// The five Home-level destinations.
enum RootTab: Hashable {
    case home, calendar, gym, study, settings
}

#Preview {
    RootView()
        .environment(ModelAvailability())
        .environment(CaptureCoordinator.shared)
}
