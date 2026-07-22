import SwiftUI

/// Home — a light "what needs me" view, not a command center.
///
/// Deliberately short: a calm greeting, what's next, any smart suggestions, and the running
/// list of things to get to whenever. The full day-by-day schedule lives in the Day tab; the
/// deadline-pressure cards (overdue, mental-load, plan-my-day) are gone — this app is for
/// someone who sets their own schedule, so nothing here scolds. Projects are one tap away.
///
/// For a cognitive-offload app an empty Home is a *result*, so the clear state reads as a
/// reward rather than a blank list.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var projectStore = ProjectStore()
    @State private var editing: TaskItem?
    @State private var now = Date()
    @State private var appeared = false
    @State private var addingTask = false
    @State private var editingPins = false
    @State private var focusTask: TaskItem?
    @AppStorage(PinnedProjects.key) private var pinnedCSV = ""
    private var patterns: PatternService { PatternService.shared }

    private var pinnedSummaries: [ProjectStore.Summary] {
        PinnedProjects.resolve(PinnedProjects.parse(pinnedCSV), from: projectStore.summaries)
    }

    private var summary: DaySummary {
        DayDashboard.summary(tasks: store.allTasks, events: store.todayEvents, now: now)
    }

    /// The single running list: things with no plan, plus anything whose soft day slipped —
    /// surfaced quietly (each row says "was planned Fri"), never in a red overdue card. Slipped
    /// items sort first so they're not buried, but they carry no alarm.
    private var loose: [TaskItem] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let undated = store.openTasks.filter { DueDate.parse($0.dueDate) == nil }
        let carried = store.openTasks
            .filter { task in
                guard let due = DueDate.parse(task.dueDate) else { return false }
                return due < startOfToday
            }
            .sorted { (DueDate.parse($0.dueDate) ?? now) < (DueDate.parse($1.dueDate) ?? now) }
        return carried + HomeGrouping.inDisplayOrder(undated)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard.appearIn(0, when: appeared)
                    captureBar.appearIn(1, when: appeared)
                    PinnedBento(summaries: pinnedSummaries) { editingPins = true }
                        .appearIn(2, when: appeared).scrollAppear()

                    if !summary.isClear || summary.nextTask != nil {
                        nowAndNext.appearIn(3, when: appeared).scrollAppear()
                    }
                    if !patterns.suggestions.isEmpty {
                        suggestionsCard.appearIn(4, when: appeared).scrollAppear()
                    }
                    if !loose.isEmpty {
                        looseCard.appearIn(5, when: appeared).scrollAppear()
                    }
                    projectsLink.appearIn(6, when: appeared).scrollAppear()

                    if store.openTasks.isEmpty && summary.completedToday == 0 {
                        EmptyCaptureInvitation { capture.beginCapture() }
                            .padding(.top, 20)
                            .appearIn(3, when: appeared)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Home")
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
                    Button { capture.beginCapture() } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Quick Capture")
                }
            }
            .task { await store.observe() }
            .task { await projectStore.observe() }
            .task { await store.loadEvents(around: now) }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    withAnimation(Motion.standard) { now = Date() }
                }
            }
            // Keep reminders matched to whatever just changed.
            .onChange(of: store.allTasks.count) { _, _ in
                Task { await NotificationSync.shared.refresh() }
            }
            .sheet(item: $editing) { task in
                NavigationStack { TaskDetailView(task: task) }
            }
            .sheet(isPresented: $addingTask) {
                AddTaskSheet(initialDate: nil)
            }
            .sheet(isPresented: $editingPins) {
                PinEditSheet(summaries: projectStore.summaries)
            }
            .fullScreenCover(item: $focusTask) { task in
                FocusSessionView(task: task, minutes: task.effortMinutes ?? 25)
            }
            .overlay(alignment: .bottom) { undoOverlay }
            .animation(Motion.standard, value: store.undo?.id)
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

    private var heroCard: some View {
        let s = summary
        let percent = Int(s.progress * 100)
        return VStack(alignment: .leading, spacing: 16) {
            Text(s.greeting.uppercased())
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

            if !heroChips(s).isEmpty {
                HStack(spacing: 8) {
                    ForEach(heroChips(s), id: \.text) { chip in
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

    // MARK: Inline capture

    /// A quick-capture pill under the hero — the fastest path from "thought" to "offloaded".
    /// Tapping anywhere on it opens the capture flow (voice or text), same as the raised action.
    private var captureBar: some View {
        Button { capture.beginCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Offload.indigo)
                Text("Say what's on your mind…")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                Spacer(minLength: 0)
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
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
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.white.opacity(0.16), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .foregroundStyle(.white)
    }

    // MARK: Now & Next

    private var nowAndNext: some View {
        let s = summary
        return card("Next", icon: "arrow.forward.circle.fill", tint: Color.Offload.indigo) {
            VStack(spacing: 12) {
                if let event = s.nextEvent {
                    HStack(spacing: 12) {
                        iconBadge("calendar", tint: Color.Offload.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.Offload.taskTitle)
                                .foregroundStyle(Color.Offload.text)
                            Text(event.isAllDay ? "All day" : CalendarView.time(event.start))
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

    private var looseCard: some View {
        card("On your list", icon: "tray.fill", tint: Color.Offload.muted) {
            VStack(spacing: 2) {
                ForEach(loose) { task in
                    taskRow(task).scrollAppearSubtle()
                }
            }
        }
    }

    // MARK: Projects entry point

    /// Projects left the tab bar, and Pinned already gives one-tap access to the ones that
    /// matter most — so this is just a small, out-of-the-way link to the full list, not a card
    /// competing with Pinned for attention.
    private var projectsLink: some View {
        HStack {
            NavigationLink {
                ProjectsView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("All projects")
                        .font(.Offload.manrope(13, .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.Offload.indigo)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.Offload.indigo.opacity(0.10), in: .capsule)
            }
            .buttonStyle(.pressable(scale: 0.96))
            Spacer(minLength: 0)
        }
    }

    // MARK: Building blocks

    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 9, style: .continuous))
    }

    private func taskRow(_ task: TaskItem) -> some View {
        TaskRowView(task: task, onEdit: { editing = task }) {
            Task { await store.toggleComplete(task) }
        }
        .contextMenu { taskMenu(task) }
        .swipeToDelete { Task { await store.delete(task) } }
    }

    /// Long-press actions come from the single shared definition, so what you can do to a task
    /// never depends on which screen you found it on.
    @ViewBuilder
    private func taskMenu(_ task: TaskItem) -> some View {
        TaskContextMenu(task: task, onFocus: { focusTask = $0 }, onEdit: { editing = $0 })
    }

    private func card<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2).fontWeight(.bold)
                .tracking(0.9)
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
                .font(.system(size: 60))
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
    HomeView().environment(CaptureCoordinator.shared)
}
