import SwiftUI

/// The four Home-level destinations. Projects intentionally isn't here — it's reached from a card
/// on Home. The raised center action is Capture, not a destination.
enum RootTab: CaseIterable {
    case home, calendar, search, settings
}

/// The app shell: the selected destination filling the screen, with a floating glass tab bar and
/// a raised center Capture button over it. Replaces the native `TabView` so the center action can
/// straddle the bar the way the redesign calls for. One destination is live at a time (each
/// re-observes on appear), keeping a single set of database observations active.
struct RootTabView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var tab: RootTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.Offload.background.ignoresSafeArea()

            destination
                // Reserve room so the last scroll item clears the floating bar.
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }

            FloatingTabBar(selection: $tab) { capture.beginCapture() }
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

/// The floating glass bar: four icon buttons with a gap in the middle for the raised Capture
/// button. Frosted via `.ultraThinMaterial`, so it reads correctly in both light and dark.
struct FloatingTabBar: View {
    @Binding var selection: RootTab
    var onCapture: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                tabButton(.home, "house.fill", "Home")
                tabButton(.calendar, "calendar", "Calendar")
                Color.clear.frame(width: 58)   // slot for the raised Capture button
                tabButton(.search, "magnifyingglass", "Search")
                tabButton(.settings, "slider.horizontal.3", "Settings")
            }
            .padding(.horizontal, 10)
            .frame(height: 62)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.Offload.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 17, y: 14)
            .padding(.horizontal, 16)

            captureButton.offset(y: -20)
        }
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

    private var captureButton: some View {
        Button {
            onCapture()
            Haptics.light()
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x8A6FE0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .overlay(Circle().stroke(Color.Offload.background, lineWidth: 5))
                .shadow(color: Color(hex: 0x5A76DC).opacity(0.45), radius: 11, y: 10)
        }
        .buttonStyle(.pressable(scale: 0.92))
        .accessibilityLabel("Quick Capture")
    }
}
