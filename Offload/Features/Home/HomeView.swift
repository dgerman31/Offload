import SwiftUI

/// Home — your whole day in one place (spec §5.4 + Design Language 2.0). Opens with a hero
/// that says what actually needs you, then Now & Next, today's real timeline (calendar events
/// merged with due tasks), anything overdue, and the loose ends. For a cognitive-offload app
/// an empty Home is a *result*, so the clear state reads as a reward, not a blank list.
///
/// Motion: cards cascade in on first load, then fade/lift under the scroll as they enter and
/// leave the viewport. Every animation comes from `Motion` so the whole screen shares timing.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var editing: TaskItem?
    @State private var batchMinutes: Int?
    @State private var now = Date()
    @State private var appeared = false
    private var patterns: PatternService { PatternService.shared }

    private var summary: DaySummary {
        DayDashboard.summary(tasks: store.allTasks, events: store.todayEvents, now: now)
    }

    private var todayItems: [DayItem] {
        DayTimeline.items(tasks: store.allTasks, events: store.todayEvents, on: now)
    }

    private var overdueTasks: [TaskItem] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        return store.openTasks
            .filter { task in
                guard let due = DueDate.parse(task.dueDate) else { return false }
                return due < startOfToday
            }
            .sorted { (DueDate.parse($0.dueDate) ?? now) < (DueDate.parse($1.dueDate) ?? now) }
    }

    /// Open tasks with no due date — the "whenever" pile, kept out of the timeline.
    private var unscheduled: [TaskItem] {
        HomeGrouping.inDisplayOrder(store.openTasks.filter { DueDate.parse($0.dueDate) == nil })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                        .appearIn(0, when: appeared)

                    if !summary.isClear || summary.nextTask != nil {
                        nowAndNext
                            .appearIn(1, when: appeared)
                            .scrollAppear()
                    }
                    if !patterns.suggestions.isEmpty {
                        suggestionsCard
                            .appearIn(2, when: appeared)
                            .scrollAppear()
                    }
                    if !overdueTasks.isEmpty {
                        overdueCard
                            .appearIn(3, when: appeared)
                            .scrollAppear()
                    }
                    if !todayItems.isEmpty {
                        timelineCard
                            .appearIn(4, when: appeared)
                            .scrollAppear()
                    }
                    gotTimeCard
                        .appearIn(5, when: appeared)
                        .scrollAppear()
                    if !unscheduled.isEmpty {
                        unscheduledCard
                            .appearIn(6, when: appeared)
                            .scrollAppear()
                    }
                    if store.openTasks.isEmpty && summary.completedToday == 0 {
                        EmptyCaptureInvitation { capture.beginCapture() }
                            .padding(.top, 24)
                            .appearIn(1, when: appeared)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { capture.beginCapture() } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Quick Capture")
                }
            }
            .task { await store.observe() }
            .task { await store.loadTodayEvents() }
            .task {
                withAnimation(Motion.settle) { appeared = true }
            }
            // Keep the greeting and "next up" honest as the day moves on.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    withAnimation(Motion.standard) { now = Date() }
                }
            }
            .sheet(item: $editing) { task in
                NavigationStack { TaskEditView(task: task) }
            }
            .overlay(alignment: .bottom) {
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
            .animation(Motion.standard, value: store.undo?.id)
            .animation(Motion.standard, value: overdueTasks.count)
            .animation(Motion.standard, value: todayItems.count)
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        let s = summary
        let percent = Int(s.progress * 100)
        return VStack(alignment: .leading, spacing: 16) {
            Text(s.greeting.uppercased())
                .font(.caption).fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.7))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.headline)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .tracking(-0.8)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Text(s.subhead)
                        .font(.Offload.body)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if s.completedToday > 0 || s.dueTodayCount > 0 || s.overdueCount > 0 {
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
                    // A soft top-left sheen — the detail that keeps a flat gradient from
                    // looking like a solid block.
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.22), .clear],
                                center: .topLeading, startRadius: 0, endRadius: 320
                            )
                        )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .elevated(.high)
        .animation(Motion.settle, value: s.headline)
    }

    private struct HeroChip { let text: String; let icon: String }

    private func heroChips(_ s: DaySummary) -> [HeroChip] {
        var chips: [HeroChip] = []
        if s.overdueCount > 0 { chips.append(.init(text: "\(s.overdueCount) overdue", icon: "exclamationmark.triangle.fill")) }
        if s.dueTodayCount > 0 { chips.append(.init(text: "\(s.dueTodayCount) due", icon: "checklist")) }
        if s.eventCount > 0 { chips.append(.init(text: "\(s.eventCount) event\(s.eventCount == 1 ? "" : "s")", icon: "calendar")) }
        if s.completedToday > 0 { chips.append(.init(text: "\(s.completedToday) done", icon: "checkmark.circle.fill")) }
        return chips
    }

    /// Gradient shifts with the time of day — morning warmth through evening violet.
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
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.white.opacity(0.16), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .foregroundStyle(.white)
    }

    // MARK: Now & Next

    private var nowAndNext: some View {
        let s = summary
        return card("Now & next", icon: "arrow.forward.circle.fill", tint: Color.Offload.indigo) {
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
                        iconBadge("sparkles", tint: Color.Offload.indigo)
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

    /// Small tinted glyph tile — gives rows an anchor without heavy chrome.
    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 9, style: .continuous))
    }

    // MARK: Sections

    private var overdueCard: some View {
        card("Overdue", icon: "exclamationmark.triangle.fill", tint: Color.Offload.red) {
            VStack(spacing: 2) {
                ForEach(overdueTasks) { task in
                    taskRow(task).scrollAppearSubtle()
                }
            }
        }
    }

    private var timelineCard: some View {
        card("Today", icon: "clock.fill", tint: Color.Offload.teal) {
            VStack(spacing: 10) {
                ForEach(todayItems) { item in
                    Group {
                        switch item {
                        case let .event(event):
                            HStack(spacing: 11) {
                                Capsule()
                                    .fill(event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal)
                                    .frame(width: 3.5, height: 32)
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
                        case let .task(task):
                            taskRow(task)
                        }
                    }
                    .scrollAppearSubtle()
                }
            }
        }
    }

    private var unscheduledCard: some View {
        card("Whenever", icon: "tray.fill", tint: Color.Offload.muted) {
            VStack(spacing: 2) {
                ForEach(unscheduled) { task in
                    taskRow(task).scrollAppearSubtle()
                }
            }
        }
    }

    private var gotTimeCard: some View {
        card("Got some time?", icon: "timer", tint: Color.Offload.amber) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        let selected = batchMinutes == minutes
                        Button {
                            withAnimation(Motion.standard) {
                                batchMinutes = selected ? nil : minutes
                            }
                            Haptics.light()
                        } label: {
                            Text("\(minutes)m")
                                .font(.caption).fontWeight(.semibold)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(
                                    selected ? Color.Offload.indigo : Color.Offload.muted.opacity(0.12),
                                    in: .capsule
                                )
                                .foregroundStyle(selected ? .white : Color.Offload.text)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                if let minutes = batchMinutes {
                    let batch = EnergyBatch.plan(tasks: store.openTasks, minutes: minutes)
                    if batch.isEmpty {
                        Text("Nothing fits in \(minutes) min right now.")
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.muted)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(batch) { task in taskRow(task) }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

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

    // MARK: Building blocks

    private func taskRow(_ task: TaskItem) -> some View {
        TaskRowView(task: task, onEdit: { editing = task }) {
            Task { await store.toggleComplete(task) }
        }
    }

    /// One consistent card shell — a tinted, tracked title row over an elevated surface.
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

/// A dismissible AI suggestion (spec §3.6). Recurrences get an Accept action that
/// applies the inferred RRULE; nudges are informational with a dismiss.
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

/// Transient "undo" banner shown after a completion/deletion (spec §5.7).
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
        // Solid, not translucent — the banner must stay legible over any content it covers.
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
