import SwiftUI

/// The whole standing picture — the running list, pinned projects, what's next, habits, groceries,
/// suggestions. **This is Home.**
///
/// It briefly wasn't: for one release Home was four single-purpose phase screens the clock picked
/// between, and all of this sat behind a button in the corner. That got the emphasis backwards —
/// the full board is what you open the app for nearly every time, and the day's rituals are the
/// exception. They arrive over the top of this now; see `HomeView` and `PhaseRitualView`.
///
/// For a cognitive-offload app an empty list is a *result*, so the clear state reads as a
/// reward rather than a blank list.
struct EverythingView: View {
    /// Opens one of the day's rituals on demand, from the ⋯ menu. Nil when this view is being used
    /// somewhere the rituals don't belong.
    var onOpenRitual: ((DayPhase) -> Void)?

    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var projectStore = ProjectStore()
    @State private var editing: TaskItem?
    @State private var now = Date()
    @State private var appeared = false
    @State private var addingTask = false
    @State private var searching = false
    @State private var editingPins = false
    @State private var planningDay = false
    @State private var justPlannedDay = false
    @State private var activeRitual: RitualView.Mode?
    @State private var pendingReschedule: TaskItem?
    /// Which tasks currently have their steps folded open. Held here rather than per-row so the
    /// state survives the list re-sorting under you as things get ticked off.
    @State private var expandedTaskIDs: Set<String> = []
    @AppStorage(PinnedProjects.key) private var pinnedCSV = ""
    private var patterns: PatternService { PatternService.shared }

    private var pinnedSummaries: [ProjectStore.Summary] {
        PinnedProjects.resolve(PinnedProjects.parse(pinnedCSV), from: projectStore.summaries)
    }

    private var summary: DaySummary {
        DayDashboard.summary(tasks: store.allTasks, events: store.todayEvents, now: now)
    }

    /// Hard-committed tasks (a real time and date) still sitting in a past day, unresolved.
    /// `OverdueSweeper` never silently moves these — the app can't guess what new time you'd
    /// want — so they surface as a reschedule-or-delete decision instead.
    private var needsDecisionTasks: [TaskItem] {
        OverdueSweeper.classify(store.allTasks, now: now).needsDecision
    }

    private func checkForPendingDecision() {
        guard pendingReschedule == nil, let next = needsDecisionTasks.first else { return }
        pendingReschedule = next
    }

    /// The single running list: things with no plan, plus anything whose soft day slipped —
    /// surfaced quietly (each row says "was planned Fri"), never in a red overdue card. Slipped
    /// items sort first so they're not buried, but they carry no alarm.
    ///
    /// Only *root* tasks appear here. A step belongs under the task it's a step of (see
    /// `stepsByParent`), not loose in the list as if it were its own errand — "buy milk" and "call
    /// the pharmacy back" read as unrelated chores once they're flattened side by side, which is
    /// exactly the sense in which steps were getting "inputed as separate tasks".
    ///
    /// Takes the open tasks rather than reading `store.openTasks` itself: that's a filter over
    /// every task, and `body` already needs the same list for its empty-state check.
    ///
    /// One `DueDate.parse` per root, in a single pass. The two filters used to parse every root
    /// twice, and the sort's comparator parsed *both* sides on every comparison — the exact
    /// pattern `DueDate`'s formatter cache exists to make survivable, done in the one place where
    /// caching the formatter still leaves O(n log n) string parses.
    private func looseTasks(from openTasks: [TaskItem]) -> [TaskItem] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        var undated: [TaskItem] = []
        var carried: [(task: TaskItem, due: Date)] = []
        // Ideas, notes, questions and decisions are deliberately absent: they live in the project
        // they belong to, not in a running list of things to get to. Mixing them back in here is
        // the exact flattening the taxonomy exists to undo.
        for task in HomeGrouping.rootsOnly(openTasks.filter { $0.captureKind.isSchedulable }) {
            guard let due = DueDate.parse(task.dueDate) else {
                undated.append(task)
                continue
            }
            if due < startOfToday { carried.append((task, due)) }
        }
        return carried.sorted { $0.due < $1.due }.map(\.task)
            + HomeGrouping.inDisplayOrder(undated)
    }

    /// Every task's steps, in the order they were added, including finished ones — a "1 of 4" that
    /// only counts what's left would go backwards as you tick things off.
    ///
    /// Grouped once per render rather than filtered per row: the per-row version was O(rows × all
    /// tasks), which at 20 rows and 500 tasks is 10,000 comparisons — twice over, since an
    /// expanded row asked again.
    private var stepsByParent: [String: [TaskItem]] {
        Dictionary(grouping: store.allTasks.filter { $0.parentTaskId != nil && !$0.deleted },
                   by: { $0.parentTaskId ?? "" })
    }

    var body: some View {
        // Each of these is a full pass over every task, so they're computed once here and threaded
        // down as parameters. `summary` was being rebuilt five times per body evaluation (a filter
        // with a `DueDate.parse` per task, plus a `NextBest.pick` over a fresh filter), `loose`
        // twice, and the 60-second clock tick re-ran the lot while the app sat idle.
        let s = summary
        let openTasks = store.openTasks
        let loose = looseTasks(from: openTasks)
        let steps = stepsByParent
        // Hoisted for the same reason as the rest: it's another full pass over every task, and the
        // minute clock re-runs this body while the app sits idle.
        let closingTime = EveningShutdown.shouldOffer(tasks: store.allTasks, now: now)
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard(s).appearIn(0, when: appeared)
                    // Always visible, never conditionally hidden — a feature you have to
                    // discover by having exactly the right state isn't discoverable at all.
                    // If there's genuinely nothing to plan, the sheet itself says so.
                    // In the evening this is the more useful of the two: "I'm up" reorganizes what's
                    // left of a day that's already over. It appears above rather than replacing it,
                    // since planning tomorrow at 10pm is still a legitimate thing to want.
                    if closingTime {
                        EveningShutdownCard(tasks: store.allTasks, now: now, store: store)
                            .appearIn(1, when: appeared)
                    }
                    wakeUpButton.appearIn(1, when: appeared)
                    captureBar.appearIn(1, when: appeared)
                    PinnedBento(summaries: pinnedSummaries) { editingPins = true }
                        .appearIn(2, when: appeared).scrollAppear()

                    // Above what's next, because on a day with 300 cards due it *is* what's next —
                    // and it removes itself entirely once the queue is clear, so its absence is the
                    // signal rather than a card reading "0 left".
                    AnkiProgressCard()
                        .appearIn(3, when: appeared).scrollAppear()

                    if !s.isClear || s.nextTask != nil {
                        nowAndNext(s).appearIn(3, when: appeared).scrollAppear()
                    }
                    if !patterns.suggestions.isEmpty {
                        suggestionsCard.appearIn(4, when: appeared).scrollAppear()
                    }
                    if !loose.isEmpty {
                        looseCard(loose, stepsByParent: steps).appearIn(5, when: appeared).scrollAppear()
                    }
                    // Habits and groceries sit below the day's work, not above it: they're standing
                    // routines rather than things competing for attention with what's due now.
                    DailyHabitsCard()
                        .appearIn(6, when: appeared).scrollAppear()
                    GroceryCard()
                        .appearIn(7, when: appeared).scrollAppear()

                    projectsLink.appearIn(8, when: appeared).scrollAppear()

                    if openTasks.isEmpty && s.completedToday == 0 {
                        EmptyCaptureInvitation { capture.beginCapture() }
                            .padding(.top, 20)
                            .appearIn(3, when: appeared)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
                // Belt and braces after the `FlowLayout` fix: this pins the scroll content to
                // exactly the scroll view's width, so no future child can make the screen
                // draggable sideways by asking for more. A `UIScrollView` scrolls on any axis
                // where content exceeds bounds, and that has now been reported twice.
                .containerRelativeFrame(.horizontal)
            }
            .scrollIndicators(.hidden)
            .closesSwipeRailsOnScroll()
            .background(Color.Offload.background)
            .navigationTitle("Everything")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { addingTask = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Add task")
                }
                ToolbarItem(placement: .primaryAction) {
                    // Search moved off the tab bar (Study took its slot) but stays one tap
                    // away rather than disappearing, same reachability the capture/add icons
                    // already get here.
                    Button { searching = true } label: {
                        Image(systemName: "magnifyingglass.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Search")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { capture.beginCapture() } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Quick Capture")
                }
                if let onOpenRitual {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            // The rituals, on demand. They come to you at the right hour on their
                            // own; this is for the times you want one early, or want it back after
                            // waving it off.
                            ForEach(DayPhase.allCases) { phase in
                                Button {
                                    onOpenRitual(phase)
                                } label: {
                                    Label(phase.invitation, systemImage: phase.symbol)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title2)
                        }
                        .accessibilityLabel("Rituals")
                    }
                }
            }
            .task { await store.observe() }
            .task { await projectStore.observe() }
            .task { await store.loadEvents(around: now) }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .task {
                // A background clock tick to keep "is this overdue now" correct — not a user
                // action, so it shouldn't animate the whole dependent view tree every minute.
                // Anything that wants its own transition (the progress ring) already has one.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = Date()
                }
            }
            .task {
                // The standing rule that nothing sits in a past day — runs once per calendar
                // day. Flexible tasks move to today silently; anything with a real hard
                // commitment surfaces below instead of being moved for you.
                guard OverdueSweeper.shouldRun() else { return }
                _ = await store.sweepOverdue()
                checkForPendingDecision()
            }
            // Keep reminders matched to whatever just changed, and re-check for anything that
            // now needs a reschedule-or-delete decision.
            .onChange(of: store.allTasks.count) { _, _ in
                Task { await NotificationSync.shared.refresh() }
                checkForPendingDecision()
            }
            .confirmationDialog(
                "Passed",
                isPresented: Binding(get: { pendingReschedule != nil }, set: { if !$0 { pendingReschedule = nil } }),
                presenting: pendingReschedule
            ) { task in
                Button("Reschedule") {
                    editing = task
                    pendingReschedule = nil
                }
                Button("Delete", role: .destructive) {
                    Task { await store.delete(task) }
                    pendingReschedule = nil
                }
            } message: { task in
                Text("“\(task.title)” was scheduled for a specific time that's already passed.")
            }
            .sheet(item: $editing) { task in
                NavigationStack { TaskDetailView(task: task) }
            }
            .sheet(isPresented: $addingTask) {
                AddTaskSheet(initialDate: nil)
            }
            .sheet(isPresented: $searching) {
                SearchView()
            }
            .sheet(isPresented: $editingPins) {
                PinEditSheet(summaries: projectStore.summaries)
            }
            .sheet(isPresented: $planningDay, onDismiss: {
                // Sequenced, not simultaneous: present the morning brief only after the plan
                // sheet has fully dismissed, so the two sheets never overlap.
                if justPlannedDay {
                    justPlannedDay = false
                    activeRitual = .morning
                }
            }) {
                DayPlanView(tasks: store.allTasks, events: store.rangeEvents, day: now) {
                    justPlannedDay = true
                    Task { await NotificationSync.shared.refresh() }
                }
            }
            .sheet(item: $activeRitual) { mode in
                RitualView(mode: mode, tasks: store.allTasks, events: store.rangeEvents)
            }
            // Scoped to just the overlay, not the whole screen: this used to sit on the
            // NavigationStack itself, which meant *every* change to `store.undo` put the entire
            // scroll content — including whatever row a delete/complete had just added or
            // removed from the ForEach below — into the same animated transaction as the banner.
            // A delete both changes `undo` and removes a row at the same instant, so that's
            // exactly the moment two unrelated animations could collide and produce a visibly
            // wrong result elsewhere on screen (the "zoomed in" report). The banner's own
            // `.transition` still animates fine from an animation this close to it.
            .overlay(alignment: .bottom) {
                undoOverlay.animation(Motion.standard, value: store.undo?.id)
            }
        }
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

    // MARK: Hero

    /// Takes the day's summary rather than reading it — recomputing `summary` per call site is
    /// what made one body evaluation five full passes over every task.
    private func heroCard(_ s: DaySummary) -> some View {
        let percent = Int(s.progress * 100)
        let chips = heroChips(s)
        return VStack(alignment: .leading, spacing: 16) {
            Text(s.greeting)
                .font(.Offload.manrope(11, .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.75))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.headline)
                        .font(.Offload.display())
                        .tracking(-1.2)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(s.subhead)
                        .font(.Offload.body)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if s.completedToday > 0 || s.dueTodayCount > 0 {
                    progressRing(s.progress, percent: percent)
                }
            }

            if !chips.isEmpty {
                // `FlowLayout`, not an `HStack`. Three chips at a large Dynamic Type size are
                // wider than the phone, and an over-wide child inside a vertical `ScrollView` is
                // not merely clipped: `UIScrollView` scrolls on any axis where the content
                // exceeds its bounds, so the whole screen could be dragged sideways. Wrapping
                // removes the overflow, which removes the drag.
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(chips, id: \.text) { chip in
                        heroChip(chip.text, chip.icon)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(heroGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            RadialGradient(colors: [.white.opacity(0.22), .clear],
                                           center: .topLeading, startRadius: 0, endRadius: 320)
                        )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .elevated(.high)
        .animation(Motion.settle, value: s.headline)
    }

    // MARK: Wake-up replan

    /// An explicit trigger — never automatic — that reorganizes whatever's left of today from
    /// right now: undated work and whole-day intentions get a real try at fitting into what's
    /// actually left of the day. Tapping it records this exact moment as "when the day started"
    /// (stronger evidence than a passive app-open), which shapes the planner's window, and once
    /// the resulting schedule is submitted, hands straight into the morning brief.
    private var wakeUpButton: some View {
        Button {
            WakeTracker.recordWake(now: Date())
            Haptics.light()
            planningDay = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sunrise.fill")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x8A6FE0)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 13, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("I'm up")
                        .font(.Offload.manrope(16, .bold))
                        .foregroundStyle(Color.Offload.text)
                    Text("Reorganize today from right now")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Color.Offload.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offloadCard()
        }
        .buttonStyle(.pressable(scale: 0.99))
    }

    // MARK: Inline capture

    /// A quick-capture pill under the hero — the fastest path from "thought" to "offloaded".
    /// Tapping anywhere on it opens the capture flow (voice or text), same as the raised action.
    private var captureBar: some View {
        Button { capture.beginCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.Offload.indigoText)
                Text("Say what's on your mind…")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                Spacer(minLength: 0)
                Image(systemName: "mic.fill")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.Offload.indigo, in: Circle())
            }
            .padding(.vertical, 8)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.Offload.surface)
                    .shadow(color: Color.black.opacity(0.06), radius: 10, y: 8)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(Color.Offload.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.pressable(scale: 0.99))
    }

    private struct HeroChip { let text: String; let icon: String }

    /// Calm, factual chips — what's scheduled, what's planned, what's done. No red "overdue"
    /// alarm; slipped work is just part of the running list below.
    private func heroChips(_ s: DaySummary) -> [HeroChip] {
        var chips: [HeroChip] = []
        if s.eventCount > 0 { chips.append(.init(text: "\(s.eventCount) scheduled", icon: "calendar")) }
        if s.dueTodayCount > 0 { chips.append(.init(text: "\(s.dueTodayCount) planned", icon: "checklist")) }
        if s.completedToday > 0 { chips.append(.init(text: "\(s.completedToday) done", icon: "checkmark.circle.fill")) }
        return chips
    }

    private var heroGradient: LinearGradient {
        let hour = Calendar.current.component(.hour, from: now)
        let colors: [Color] = switch hour {
        case 5..<12:  [Color(hex: 0x3B4CB8), Color(hex: 0x8A6FE0)]
        case 12..<17: [Color(hex: 0x2E3B8C), Color(hex: 0x5A76DC)]
        case 17..<22: [Color(hex: 0x3A2E7A), Color(hex: 0x8A55B8)]
        default:      [Color(hex: 0x141735), Color(hex: 0x3A2E7A)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func progressRing(_ progress: Double, percent: Int) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.settle, value: progress)
            Text("\(percent)%")
                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(percent)))
                .animation(Motion.settle, value: percent)
        }
        .frame(width: 62, height: 62)
        .accessibilityLabel("\(percent) percent of today done")
    }

    private func heroChip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).fontWeight(.medium)
            // Deliberately no `.fixedSize()`: it refuses to compress, which is what let a chip
            // push the content wider than the screen in the first place.
            .lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.white.opacity(0.16), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .foregroundStyle(.white)
    }

    // MARK: Now & Next

    private func nowAndNext(_ s: DaySummary) -> some View {
        card("Next", icon: "arrow.forward.circle.fill", tint: Color.Offload.indigoText) {
            VStack(spacing: 12) {
                if let event = s.nextEvent {
                    HStack(spacing: 12) {
                        iconBadge("calendar", tint: Color.Offload.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.Offload.taskTitle)
                                .foregroundStyle(Color.Offload.text)
                            Text(event.isAllDay ? "All day" : TimeFormat.time(event.start))
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let task = s.nextTask {
                    HStack(spacing: 12) {
                        iconBadge("sparkles", tint: Color.Offload.accent(for: task.category))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.Offload.taskTitle)
                                .foregroundStyle(Color.Offload.text)
                            Text(task.effortMinutes.map { "~\($0) min · start here" } ?? "Start here")
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task { await store.toggleComplete(task) }
                        } label: {
                            Text("Do it")
                                .font(.caption).fontWeight(.semibold)
                                .padding(.horizontal, 15).padding(.vertical, 8)
                                .background(Color.Offload.indigo, in: .capsule)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    // MARK: Suggestions

    private var suggestionsCard: some View {
        card("Suggestions", icon: "lightbulb.fill", tint: Color.Offload.amber) {
            VStack(spacing: 12) {
                ForEach(patterns.suggestions) { pattern in
                    SuggestionCard(pattern: pattern,
                                   onAccept: { Task { await patterns.accept(pattern) } },
                                   onDismiss: { Task { await patterns.dismiss(pattern) } })
                }
            }
        }
    }

    // MARK: The running list

    private func looseCard(_ loose: [TaskItem], stepsByParent: [String: [TaskItem]]) -> some View {
        card("On your list", icon: "tray.fill", tint: Color.Offload.muted) {
            VStack(spacing: 2) {
                ForEach(loose) { task in
                    let taskSteps = stepsByParent[task.id] ?? []
                    VStack(spacing: 2) {
                        taskRow(task, steps: taskSteps)
                        // Steps stay folded away by default — the point of Home is "what needs
                        // me", and a task's internal breakdown is detail you ask for.
                        if expandedTaskIDs.contains(task.id) {
                            ForEach(taskSteps) { step in
                                stepRow(step)
                            }
                        }
                    }
                    .scrollAppearSubtle()
                }
            }
        }
    }

    /// One step, nested under its parent. Indented and quieter than a root row, so the hierarchy
    /// is legible at a glance rather than implied by position alone.
    private func stepRow(_ step: TaskItem) -> some View {
        TaskRowView(task: step, indented: true, onEdit: nil) {
            Task { await store.toggleComplete(step) }
        }
        .contextMenu { taskMenu(step) }
        .swipeToDelete(id: step.id, onTap: { openTask(step) }) { Task { await store.delete(step) } }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Projects entry point

    /// Projects left the tab bar, and Pinned already gives one-tap access to the ones that
    /// matter most — so this is just a small, out-of-the-way pair of links, not a card competing
    /// with Pinned for attention. "On your list" above is a curated running list, not everything —
    /// this is where "show me literally all my tasks" lives, one tap away like Projects.
    private var projectsLink: some View {
        // Wrapping for the same reason as the hero chips — two capsules side by side overflow at
        // the larger accessibility sizes, and an overflow here drags the whole screen sideways.
        FlowLayout(spacing: 10, lineSpacing: 8) {
            NavigationLink {
                AllTasksView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(.caption, weight: .semibold))
                    Text("All tasks")
                        .font(.Offload.manrope(13, .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2, weight: .semibold))
                }
                .foregroundStyle(Color.Offload.indigoText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.Offload.indigo.opacity(0.10), in: .capsule)
            }
            .buttonStyle(.pressable(scale: 0.96))

            NavigationLink {
                ProjectsView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(.caption, weight: .semibold))
                    Text("All projects")
                        .font(.Offload.manrope(13, .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2, weight: .semibold))
                }
                .foregroundStyle(Color.Offload.indigoText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.Offload.indigo.opacity(0.10), in: .capsule)
            }
            .buttonStyle(.pressable(scale: 0.96))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Building blocks

    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 9, style: .continuous))
    }

    private func taskRow(_ task: TaskItem, steps taskSteps: [TaskItem]) -> some View {
        // `onEdit: nil` — the row's own tap-to-open moves to `.swipeToDelete`'s `onTap` instead
        // of `TaskRowView`'s internal `.onTapGesture`, which would otherwise be a second,
        // independent gesture recognizer racing the swipe's drag on the same touch (exactly
        // what let a completed swipe still open the task's detail).
        return HStack(spacing: 4) {
            TaskRowView(task: task, onEdit: nil) {
                Task { await store.toggleComplete(task) }
            }
            if !taskSteps.isEmpty {
                stepsDisclosure(for: task, steps: taskSteps)
            }
        }
        .contextMenu { taskMenu(task) }
        .swipeToDelete(id: task.id, onTap: { openTask(task) }) { Task { await store.delete(task) } }
    }

    /// The fold-out control for a task's steps, carrying its own progress ("2/5") so the count is
    /// useful while collapsed — otherwise you'd have to open it just to learn whether it's worth
    /// opening. A real `Button`, so it claims its own taps rather than the row's open action.
    private func stepsDisclosure(for task: TaskItem, steps: [TaskItem]) -> some View {
        let expanded = expandedTaskIDs.contains(task.id)
        let done = steps.filter { $0.status == "completed" }.count
        return Button {
            Haptics.light()
            withAnimation(Motion.snappy) {
                if expanded { expandedTaskIDs.remove(task.id) } else { expandedTaskIDs.insert(task.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(done)/\(steps.count)")
                    .font(.Offload.data)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(.caption2, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .foregroundStyle(Color.Offload.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.Offload.muted.opacity(0.10), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(expanded ? "Hide steps" : "Show \(steps.count) steps, \(done) done")
    }

    /// A task that's really the schedule block for a Gym-tab session opens the Gym tab to that
    /// session instead of the normal task detail — its real content lives only there.
    private func openTask(_ task: TaskItem) {
        if let gymSessionId = task.gymSessionId {
            AppNavigation.shared.openGymSession(gymSessionId)
        } else {
            editing = task
        }
    }

    /// Long-press actions come from the single shared definition, so what you can do to a task
    /// never depends on which screen you found it on.
    @ViewBuilder
    private func taskMenu(_ task: TaskItem) -> some View {
        TaskContextMenu(task: task, onFocus: { FocusTimer.shared.start(task: $0) }, onEdit: openTask)
    }

    private func card<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Sentence case, no letter-spacing: iOS labels a section the way it labels anything
            // else. Tracked all-caps is a web/editorial idiom and reads as "designed elsewhere"
            // next to the system's own headers.
            Label(title, systemImage: icon)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }
}

/// A dismissible AI suggestion (spec §3.6).
struct SuggestionCard: View {
    let pattern: Pattern
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pattern.title ?? "")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
            HStack(spacing: 10) {
                if pattern.patternType == "recurrence" {
                    Button(action: onAccept) {
                        Text("Make it recurring")
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.Offload.indigo, in: .capsule)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.pressable)
                }
                Button(action: onDismiss) {
                    Text(pattern.patternType == "recurrence" ? "No thanks" : "Got it")
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.Offload.muted.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.muted)
                }
                .buttonStyle(.pressable)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Transient "undo" banner shown after a completion/deletion/snooze (spec §5.7).
struct UndoBanner: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.Offload.body)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.teal)
                .buttonStyle(.pressable)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color(hex: 0x1F2937), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .elevated(.high)
    }
}

/// Reusable empty-state used across tabs — an invitation, not decoration (spec §5.6).
struct EmptyCaptureInvitation: View {
    var onCapture: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(.largeTitle))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x8A6FE0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Text("Mind clear")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.Offload.text)
            Text("Nothing needs you right now. Press the Action Button — or tap below — and just say what's on your mind.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .multilineTextAlignment(.center)
            Button(action: onCapture) {
                Label("Capture a thought", systemImage: "mic.fill")
                    .font(.Offload.taskTitle)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.pressable)
            .padding(.top, 4)
        }
        .frame(maxWidth: 360)
    }
}

#Preview {
    EverythingView().environment(CaptureCoordinator.shared)
}
