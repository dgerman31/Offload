import SwiftUI

/// The Home tab: the whole picture, with the day's rituals arriving over it.
///
/// ### What changed, and why
///
/// For one release Home *was* the phase screens — the clock picked one of four and that was the
/// app's front door, with the full board behind a button in the corner. It got the emphasis
/// backwards. The complete picture is what you open the app for almost every time; a ritual is the
/// exception. An exception belongs on top of the main screen, not in place of it.
///
/// So `EverythingView` is Home, permanently, and `PhaseRitualView` arrives over it at the three
/// moments a day that genuinely want the whole screen — decide the day, close it out, put it down.
/// Each appears once and then gets out of the way, whether you acted on it or waved it off.
///
/// This file is deliberately thin. It decides *whether* to interrupt, and nothing else.
struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase

    /// The ritual currently on screen. `automatic` distinguishes one the clock brought from one
    /// you went looking for — only the former uses up today's turn.
    @State private var ritual: Ritual?
    @State private var runningBriefSetup = false
    @State private var now = Date()

    @AppStorage(DayPhase.plannedDayKey) private var plannedDay = ""
    @AppStorage(EveningShutdown.lastClosedKey) private var lastClosedDay = ""
    /// Whether the short "about you" setup has been offered. Once, ever — an optional setup that
    /// keeps reappearing is a mandatory setup with extra steps.
    @AppStorage("offload.lifeBrief.offered") private var briefOffered = false

    /// A phase plus how it got here. `Identifiable` so it can drive a `fullScreenCover(item:)`.
    struct Ritual: Identifiable, Equatable {
        var phase: DayPhase
        var automatic: Bool
        var id: String { phase.rawValue }
    }

    var body: some View {
        EverythingView(onOpenRitual: { phase in
            ritual = Ritual(phase: phase, automatic: false)
        })
        .fullScreenCover(item: $ritual) { ritual in
            PhaseRitualView(phase: ritual.phase, isAutomatic: ritual.automatic)
        }
        .sheet(isPresented: $runningBriefSetup) { LifeBriefSetupView() }
        // On arrival, and again whenever you come back to the app after a while — a day that
        // started before 8pm and is still open at 10 should get its wind-down prompt without
        // needing the app relaunched.
        .task { await considerInterrupting() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            now = Date()
            Task { await considerInterrupting() }
        }
    }

    /// Decide whether anything should take over the screen right now. Usually nothing should.
    ///
    /// Two possible interruptions, and they're mutually exclusive on purpose: a brand-new user gets
    /// the short "about you" setup once, and everyone else gets at most the current ritual. Being
    /// asked two things at once on launch is how an app teaches you to dismiss without reading.
    private func considerInterrupting() async {
        guard ritual == nil, !runningBriefSetup else { return }

        if LifeBrief.stored().isEmpty {
            guard !briefOffered else { return }
            briefOffered = true
            runningBriefSetup = true
            return
        }

        guard let phase = DayPhase.pendingRitual(now: now, plannedDay: plannedDay,
                                                 closedDay: lastClosedDay) else { return }
        ritual = Ritual(phase: phase, automatic: true)
    }
}

#Preview {
    HomeView().environment(CaptureCoordinator.shared)
}
