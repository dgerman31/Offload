import SwiftUI

/// The four Home-level destinations. Projects intentionally isn't here — it's reached from a
/// small button on Home. Capture isn't here either — the Action Button (and Home's own capture
/// bar) already start it, so the bar doesn't need to duplicate that.
enum RootTab: CaseIterable {
    case home, calendar, search, settings
}

/// The app shell: the selected destination filling the screen, with a floating glass tab bar
/// over it. Replaces the native `TabView` purely for the glass-capsule look — no raised center
/// button. One destination is live at a time (each re-observes on appear), keeping a single set
/// of database observations active.
struct RootTabView: View {
    @State private var tab: RootTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.Offload.background.ignoresSafeArea()

            destination
                // Reserve room so the last scroll item clears the floating bar.
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 48) }

            FloatingTabBar(selection: $tab)
        }
    }

    @ViewBuilder private var destination: some View {
        switch tab {
        case .home:     HomeView()
        case .calendar: DayView()
        case .search:   SearchView()
        case .settings: SettingsView()
        }
    }
}

/// The floating glass bar: four evenly-spaced icon buttons, no gap, no raised center button.
/// Frosted via `.ultraThinMaterial`, so it reads correctly in both light and dark.
struct FloatingTabBar: View {
    @Binding var selection: RootTab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.home, "house.fill", "Home")
            tabButton(.calendar, "calendar", "Calendar")
            tabButton(.search, "magnifyingglass", "Search")
            tabButton(.settings, "slider.horizontal.3", "Settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.Offload.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 17, y: 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(_ tab: RootTab, _ icon: String, _ label: String) -> some View {
        let active = selection == tab
        return Button {
            withAnimation(Motion.standard) { selection = tab }
            Haptics.light()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: active ? .bold : .regular))
                .foregroundStyle(active ? Color.Offload.indigo : Color.Offload.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(label)
    }
}
