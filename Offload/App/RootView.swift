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

    /// The tab bar's selection, with one extra job: choosing Day means "take me to today".
    ///
    /// Wrapped rather than binding straight to `nav.selectedTab` so the press is observable even
    /// when the selection doesn't change — pressing Day while already on Day is exactly when you
    /// most want it to jump back from whatever week you'd wandered into.
    private var tabSelection: Binding<RootTab> {
        Binding(
            get: { AppNavigation.shared.selectedTab },
            set: { tab in
                if tab == .calendar { AppNavigation.shared.requestToday() }
                AppNavigation.shared.selectedTab = tab
            }
        )
    }

    var body: some View {
        @Bindable var capture = capture
        @Bindable var nav = nav

        @Bindable var timer = FocusTimer.shared

        Group {
            if onboarded {
                TabView(selection: tabSelection) {
                    Tab("Home", systemImage: "square.stack.3d.up", value: RootTab.home) { HomeView().focusMiniBar() }
                    Tab("Day", systemImage: "calendar.day.timeline.left", value: RootTab.calendar) { DayView().focusMiniBar() }
                    Tab("Gym", systemImage: "figure.strengthtraining.traditional", value: RootTab.gym) { GymView().focusMiniBar() }
                    Tab("Study", systemImage: "graduationcap.fill", value: RootTab.study) { StudyView().focusMiniBar() }
                    Tab("Settings", systemImage: "slider.horizontal.3", value: RootTab.settings) { SettingsView().focusMiniBar() }
                }
                // iOS 26: the tab bar shrinks out of the way as you read down a screen and comes
                // back the moment you scroll up. Content-first, and it's the system behaviour —
                // matching it is most of what makes an app feel native rather than adjacent.
                .tabBarMinimizeBehavior(.onScrollDown)
                .tint(Color.Offload.indigoText)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $capture.isCapturing) {
            CaptureView()
        }
        // Presented from the root rather than from each screen that can start a session. The
        // timer outlives every view now, so the thing that shows it has to sit above them all —
        // four separate `.fullScreenCover`s (Home, Day, All tasks, task detail) each owning their
        // own copy is exactly how the old one ended up with a different session per screen.
        .fullScreenCover(isPresented: $timer.isExpanded) {
            FocusSessionView()
        }
    }
}

/// The five Home-level destinations.
enum RootTab: Hashable {
    case home, calendar, gym, study, settings
}

extension View {
    /// The running focus timer, sitting just above the tab bar on whichever tab you're on.
    ///
    /// A running timer that's only visible on the screen that started it is indistinguishable from
    /// one that stopped, and this one keeps running everywhere — so it has to show everywhere.
    ///
    /// ### Why this is on each tab's content rather than on the TabView
    ///
    /// It has been in all three possible places, and the two obvious ones are both wrong:
    ///
    /// - `.safeAreaInset` **on the TabView** puts it on top of iOS 26's floating glass tab bar and
    ///   swallows the taps meant for the other tabs. Start a focus session and you're stuck on
    ///   whichever tab you were on.
    /// - `.tabViewBottomAccessory` is the slot Apple built for exactly this, and it fixes that —
    ///   but the container is drawn whether or not the content is empty, so with no timer running
    ///   you get a blank white capsule floating above the tab bar for ever. A known iOS 26 quirk,
    ///   and there's no way to suppress it from inside the accessory.
    ///
    /// Inside each tab's content there's no such problem: the tab bar is already outside this
    /// area, so nothing can be covered, and a `safeAreaInset` whose content renders nothing adds
    /// no inset at all — which is the entire behaviour we need when no session is running.
    func focusMiniBar() -> some View {
        safeAreaInset(edge: .bottom) {
            FocusMiniBar()
                .animation(Motion.standard, value: FocusTimer.shared.session?.taskId)
        }
    }
}

#Preview {
    RootView()
        .environment(ModelAvailability())
        .environment(CaptureCoordinator.shared)
}
