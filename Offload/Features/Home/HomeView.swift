import SwiftUI

/// Home, which is now four screens rather than one.
///
/// ### Why
///
/// The old Home was a single scroll that tried to be useful at every hour: a hero summary, a
/// shutdown prompt, a replan button, a capture bar, pinned projects, what's next, suggestions, the
/// running list, habits, groceries, and two links. All of it was reasonable, and all of it was
/// present at 6am, 2pm and 11pm alike — reordered slightly, never reduced. That's why a day could
/// start well and end in a scroll: at 11pm the screen still offered eleven things to do, and the
/// only one that would have helped was "stop".
///
/// So the clock now picks the screen, and each screen does one job with nothing else on it. See
/// `DayPhase` for the boundaries, two of which are decisions rather than hours — planning the day
/// ends the morning, closing it out ends the evening.
///
/// ### What didn't happen
///
/// Nothing was deleted. Everything the old Home held lives in `EverythingView`, one tap away from
/// every phase, and the phase itself can be overridden from the same menu — a screen that shows
/// you what it thinks you need has to let you disagree with it, or it's just a screen that's
/// sometimes wrong.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = TaskStore()
    @State private var now = Date()
    /// A phase chosen by hand from the menu. Cleared the moment the clock moves on by itself, so
    /// an override is a look at another screen rather than a setting you have to remember to undo.
    @State private var override: DayPhase?
    /// Tasks passed over on the Now screen this session. Not persisted — "not this one, right now"
    /// is a statement about the next ten minutes, not a property of the task.
    @State private var skipped: Set<String> = []

    /// The one question the app has for you right now, or nil — which is the usual answer. Held in
    /// state rather than recomputed in `body` because deciding it reads and *writes* the brief
    /// (asking is recorded), and a body that writes storage would ask on every render.
    @State private var briefQuestion: LifeBriefQuestion?
    @State private var runningBriefSetup = false

    @State private var showingEverything = false
    @State private var showingProjects = false
    @State private var searching = false
    @State private var planning = false
    @State private var closing = false

    /// Read through `@AppStorage` rather than `EveningShutdown.alreadyClosed()` / a plain defaults
    /// read, so that recording either one re-renders the screen — which is what lets planning the
    /// day move you to Now, and closing it move you to Wind down, the instant you do it.
    @AppStorage(DayPhase.plannedDayKey) private var plannedDay = ""
    @AppStorage(EveningShutdown.lastClosedKey) private var lastClosedDay = ""
    /// Whether the short "about you" setup has been put in front of the user. Once, ever — an
    /// optional setup that keeps reappearing is a mandatory setup with extra steps.
    @AppStorage("offload.lifeBrief.offered") private var briefOffered = false

    private var derivedPhase: DayPhase {
        DayPhase.current(now: now, plannedDay: plannedDay, closedDay: lastClosedDay)
    }

    private var phase: DayPhase { override ?? derivedPhase }

    var body: some View {
        NavigationStack {
            ZStack {
                phase.wash
                surface()
                    .transition(.opacity)
            }
            .animation(Motion.page, value: phase)
            .navigationTitle(phase.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .overlay(alignment: .bottom) {
                undoOverlay.animation(Motion.standard, value: store.undo?.id)
            }
            .task { await store.observe() }
            .task { await store.loadEvents(around: now) }
            .task {
                // Keeps the clock — and therefore the phase — honest while the app sits open.
                // A minute is plenty: the boundaries are hours.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = Date()
                }
            }
            // Coming back to the app after hours away has to land on the right screen immediately,
            // not up to a minute later.
            .onChange(of: scenePhase) { _, new in
                if new == .active { now = Date() }
            }
            // An override is only interesting until the day moves on by itself. Passed-over tasks
            // expire with it: "not this one, right now" is a statement about the next ten minutes,
            // and a new phase is a new ten minutes.
            .onChange(of: derivedPhase) { _, _ in
                override = nil
                skipped.removeAll()
            }
            // Only in the morning, and only once it's a screen you'd actually be reading. Keyed to
            // the phase so it's re-evaluated when the day moves on rather than only on first launch.
            .task(id: phase) { await considerAsking() }
            .sheet(isPresented: $showingEverything) { EverythingView() }
            .sheet(isPresented: $runningBriefSetup) {
                LifeBriefSetupView { briefQuestion = nil }
            }
            .sheet(isPresented: $showingProjects) {
                // Its own stack: `ProjectsView` expects to be pushed into one (it left the tab bar
                // long ago), and its rows push the workspace.
                NavigationStack {
                    ProjectsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingProjects = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $searching) { SearchView() }
            .sheet(isPresented: $planning) {
                DayPlanView(tasks: store.allTasks, events: store.rangeEvents, day: now) {
                    // Submitting a plan *is* the morning's decision — there's no reason to ask for
                    // it twice.
                    commitToTheDay()
                    Task { await NotificationSync.shared.refresh() }
                }
            }
            .sheet(isPresented: $closing) {
                EveningShutdownView(tasks: store.allTasks, now: now, store: store)
            }
        }
    }

    // MARK: The four screens

    /// Each branch computes only what it needs. Only one screen is ever on, and the minute ticker
    /// re-runs this while the app sits idle — building today's timeline for the Wind down screen,
    /// which shows nothing at all, is a full pass over every task for no reason.
    @ViewBuilder
    private func surface() -> some View {
        switch phase {
        case .morning:
            MorningSurface(items: todayTimeline(), now: now,
                           question: briefQuestion,
                           onPlan: { planning = true },
                           onCommit: commitToTheDay,
                           onAnswerQuestion: answerBriefQuestion,
                           onDismissQuestion: dismissBriefQuestion)
        case .midday:
            let current = middayTask()
            MiddaySurface(
                task: current,
                next: nextUp(in: todayTimeline(), after: current),
                onFocus: { chosen in
                    FocusTimer.shared.start(task: chosen)
                    FocusTimer.shared.isExpanded = true
                },
                onDone: { chosen in
                    Haptics.success()
                    Task { await store.toggleComplete(chosen) }
                },
                onPickAnother: {
                    if let current {
                        skipped.insert(current.id)
                        Haptics.light()
                    }
                },
                onCapture: { capture.beginCapture() }
            )
        case .evening:
            EveningSurface(
                summary: EveningShutdown.summary(tasks: store.allTasks, now: now),
                closed: lastClosedDay == DayPhase.dayKey(now),
                onCloseOut: { closing = true },
                onWrite: { capture.beginCapture() }
            )
        case .night:
            NightSurface(onFinished: {})
        }
    }

    // MARK: Picking the one thing

    private func todayTimeline() -> [DayItem] {
        DayTimeline.items(tasks: store.allTasks, events: store.todayEvents, on: now)
    }

    /// The single task the Now screen shows.
    ///
    /// Today's work first — anything carried over or due today — falling back to the whole open
    /// list so the screen still has something to say on a day with no plan. Passed-over tasks are
    /// filtered out, unless passing over has emptied the pool, in which case they come back rather
    /// than leaving the screen falsely clear.
    private func middayTask(calendar: Calendar = .current) -> TaskItem? {
        let startOfToday = calendar.startOfDay(for: now)
        let roots = HomeGrouping.rootsOnly(store.openTasks.filter { !$0.deleted })
        let todays = roots.filter { task in
            guard let due = DueDate.parse(task.dueDate) else { return false }
            return due < startOfToday || calendar.isDate(due, inSameDayAs: now)
        }
        let pool = todays.isEmpty ? roots : todays
        let remaining = pool.filter { !skipped.contains($0.id) }
        return NextBest.pick(from: remaining.isEmpty ? pool : remaining)
    }

    /// The horizon line under the current task: the next thing on today's timeline that hasn't
    /// happened yet and isn't the thing you're already doing.
    private func nextUp(in timeline: [DayItem], after current: TaskItem?) -> DayItem? {
        timeline.first { item in
            if item.taskId == current?.id { return false }
            if let time = item.time, time <= now { return false }
            return true
        }
    }

    /// The morning's one decision. Clears any manual override too: committing to the day means
    /// moving on from it, and an override set before planning would otherwise hold you on the
    /// morning screen you just finished with.
    // MARK: The occasional question

    /// Decide whether to ask anything this morning.
    ///
    /// Two different things live here. A brand-new user with no brief at all is offered the short
    /// setup, once ever. Everyone else gets at most one question, spaced days apart, chosen by
    /// `LifeBriefInterview` — and most mornings the answer is nothing, which is the design.
    ///
    /// Asking is recorded at the moment the question is *shown*, not when it's answered. Otherwise
    /// an ignored question would come back every single morning, which is precisely the nagging
    /// this is built to avoid.
    private func considerAsking() async {
        guard phase == .morning, briefQuestion == nil, !runningBriefSetup else { return }
        let brief = LifeBrief.stored()
        if brief.isEmpty {
            guard !briefOffered else { return }
            briefOffered = true
            runningBriefSetup = true
            return
        }
        guard let question = LifeBriefInterview.next(brief: brief, now: now) else { return }
        LifeBrief.save(LifeBriefInterview.recordAsked(question, in: brief, now: now))
        withAnimation(Motion.standard) { briefQuestion = question }
    }

    private func answerBriefQuestion(_ answer: String) {
        guard let question = briefQuestion else { return }
        LifeBrief.save(LifeBriefInterview.recordAnswered(question, answer: answer,
                                                         in: LifeBrief.stored(), now: now))
        Haptics.success()
        withAnimation(Motion.standard) { briefQuestion = nil }
    }

    private func dismissBriefQuestion() {
        guard let question = briefQuestion else { return }
        LifeBrief.save(LifeBriefInterview.recordDismissed(question, in: LifeBrief.stored(), now: now))
        withAnimation(Motion.standard) { briefQuestion = nil }
    }

    private func commitToTheDay() {
        plannedDay = DayPhase.dayKey(now)
        override = nil
        Haptics.success()
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { capture.beginCapture() } label: {
                Image(systemName: "bolt.circle.fill").font(.title2)
            }
            .buttonStyle(.pressable(scale: 0.9))
            .accessibilityLabel("Quick Capture")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Everything", systemImage: "square.stack.3d.up") { showingEverything = true }
                // Projects are where the real work is run from now, so they get their own way in
                // rather than sitting two taps deep behind Everything.
                Button("Projects", systemImage: "folder.fill") { showingProjects = true }
                Button("Search", systemImage: "magnifyingglass") { searching = true }
                Divider()
                // A `Picker` inside a `Menu` is the system's own "pick one of these" — it renders
                // as a checkmarked list for free, which is both less code and more familiar than
                // four buttons that have to indicate their own selection.
                Picker("Show", selection: phaseSelection) {
                    ForEach(DayPhase.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .accessibilityLabel("More")
        }
    }

    /// Choosing the phase the clock already picked clears the override rather than pinning it, so
    /// there's no such thing as an override you can't get out of.
    private var phaseSelection: Binding<DayPhase> {
        Binding(
            get: { phase },
            set: { chosen in
                withAnimation(Motion.page) {
                    override = chosen == derivedPhase ? nil : chosen
                }
                Haptics.light()
            }
        )
    }

    @ViewBuilder
    private var undoOverlay: some View {
        if let undo = store.undo {
            UndoBanner(message: undo.message) {
                Task { await store.performUndo() }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.id) {
                try? await Task.sleep(for: .seconds(4))
                store.clearUndo()
            }
        }
    }
}

#Preview {
    HomeView().environment(CaptureCoordinator.shared)
}
