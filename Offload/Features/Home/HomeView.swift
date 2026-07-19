import SwiftUI

/// Home — your whole day in one place (spec §5.4 + Design Language 2.0). Opens with a hero
/// that says what actually needs you, then Now & Next, today's real timeline (calendar events
/// merged with due tasks), anything overdue, and the loose ends. For a cognitive-offload app
/// an empty Home is a *result*, so the clear state reads as a reward, not a blank list.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var editing: TaskItem?
    @State private var batchMinutes: Int?
    @State private var now = Date()
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
                VStack(spacing: 16) {
                    heroCard
                    if !summary.isClear || summary.nextTask != nil { nowAndNext }
                    if !patterns.suggestions.isEmpty { suggestionsCard }
                    if !overdueTasks.isEmpty { overdueCard }
                    if !todayItems.isEmpty { timelineCard }
                    gotTimeCard
                    if !unscheduled.isEmpty { unscheduledCard }
                    if store.openTasks.isEmpty && summary.completedToday == 0 {
                        EmptyCaptureInvitation { capture.beginCapture() }
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color.Offload.background)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { capture.beginCapture() } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Quick Capture")
                }
            }
            .task { await store.observe() }
            .task { await store.loadTodayEvents() }
            // Keep the greeting and "next up" honest as the day moves on.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = Date()
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
            .animation(.snappy, value: store.undo?.id)
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        let s = summary
        return VStack(alignment: .leading, spacing: 14) {
            Text(s.greeting)
                .font(.Offload.body)
                .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.headline)
                        .font(.Offload.display(.title))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(s.subhead)
                        .font(.Offload.body)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if s.completedToday > 0 || s.dueTodayCount > 0 || s.overdueCount > 0 {
                    progressRing(s.progress)
                }
            }

            HStack(spacing: 8) {
                if s.overdueCount > 0 { heroChip("\(s.overdueCount) overdue", "exclamationmark.triangle.fill") }
                if s.dueTodayCount > 0 { heroChip("\(s.dueTodayCount) due", "checklist") }
                if s.eventCount > 0 { heroChip("\(s.eventCount) event\(s.eventCount == 1 ? "" : "s")", "calendar") }
                if s.completedToday > 0 { heroChip("\(s.completedToday) done", "checkmark.circle.fill") }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroGradient, in: .rect(cornerRadius: 22))
    }

    /// Gradient shifts with the time of day — morning warmth through evening violet.
    private var heroGradient: LinearGradient {
        let hour = Calendar.current.component(.hour, from: now)
        let colors: [Color] = switch hour {
        case 5..<12:  [Color(hex: 0x3B4CB8), Color(hex: 0x7C6BD6)]
        case 12..<17: [Color(hex: 0x2E3B8C), Color(hex: 0x4F6BD0)]
        case 17..<22: [Color(hex: 0x3A2E7A), Color(hex: 0x7A4FA8)]
        default:      [Color(hex: 0x1B1F45), Color(hex: 0x3A2E7A)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func progressRing(_ progress: Double) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .animation(.snappy, value: progress)
        .accessibilityLabel("\(Int(progress * 100)) percent of today done")
    }

    private func heroChip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.18), in: .capsule)
            .foregroundStyle(.white)
    }

    // MARK: Now & Next

    private var nowAndNext: some View {
        let s = summary
        return card("Now & next", icon: "arrow.forward.circle.fill", tint: Color.Offload.indigo) {
            VStack(spacing: 10) {
                if let event = s.nextEvent {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                            .foregroundStyle(Color.Offload.teal)
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
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.Offload.indigo)
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
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Color.Offload.indigo, in: .capsule)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var overdueCard: some View {
        card("Overdue", icon: "exclamationmark.triangle.fill", tint: Color.Offload.red) {
            VStack(spacing: 4) {
                ForEach(overdueTasks) { task in
                    taskRow(task)
                }
            }
        }
    }

    private var timelineCard: some View {
        card("Today", icon: "clock.fill", tint: Color.Offload.teal) {
            VStack(spacing: 8) {
                ForEach(todayItems) { item in
                    switch item {
                    case let .event(event):
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal)
                                .frame(width: 3, height: 30)
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
            }
        }
    }

    private var unscheduledCard: some View {
        card("Whenever", icon: "tray.fill", tint: Color.Offload.muted) {
            VStack(spacing: 4) {
                ForEach(unscheduled) { task in
                    taskRow(task)
                }
            }
        }
    }

    private var gotTimeCard: some View {
        card("Got some time?", icon: "timer", tint: Color.Offload.amber) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Button {
                            batchMinutes = (batchMinutes == minutes) ? nil : minutes
                        } label: {
                            Text("\(minutes)m")
                                .font(.caption).fontWeight(.medium)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background((batchMinutes == minutes ? Color.Offload.indigo : Color.Offload.muted).opacity(0.15), in: .capsule)
                                .foregroundStyle(batchMinutes == minutes ? Color.Offload.indigo : Color.Offload.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let minutes = batchMinutes {
                    let batch = EnergyBatch.plan(tasks: store.openTasks, minutes: minutes)
                    if batch.isEmpty {
                        Text("Nothing fits in \(minutes) min right now.")
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.muted)
                    } else {
                        ForEach(batch) { task in taskRow(task) }
                    }
                }
            }
        }
    }

    private var suggestionsCard: some View {
        card("Suggestions", icon: "lightbulb.fill", tint: Color.Offload.amber) {
            VStack(spacing: 10) {
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

    /// One consistent card shell — a tinted title row over a surface panel.
    private func card<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(tint)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.surface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Offload.divider, lineWidth: 1))
    }
}

/// A dismissible AI suggestion (spec §3.6). Recurrences get an Accept action that
/// applies the inferred RRULE; nudges are informational with a dismiss.
struct SuggestionCard: View {
    let pattern: Pattern
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pattern.title ?? "")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
            HStack(spacing: 12) {
                if pattern.patternType == "recurrence" {
                    Button(action: onAccept) {
                        Text("Make it recurring")
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.Offload.indigo, in: .capsule)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onDismiss) {
                    Text(pattern.patternType == "recurrence" ? "No thanks" : "Got it")
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.Offload.muted.opacity(0.14), in: .capsule)
                        .foregroundStyle(Color.Offload.muted)
                }
                .buttonStyle(.plain)
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
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(hex: 0x1F2937), in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

/// Reusable empty-state used across tabs — an invitation, not decoration (spec §5.6).
struct EmptyCaptureInvitation: View {
    var onCapture: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.Offload.indigo)
            Text("Nothing to organize yet")
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            Text("Press the Action Button — or tap below — and just say what's on your mind. Offload sorts it out.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .multilineTextAlignment(.center)
            Button(action: onCapture) {
                Label("Capture a thought", systemImage: "mic.fill")
                    .font(.Offload.taskTitle)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 360)
    }
}

#Preview {
    HomeView().environment(CaptureCoordinator.shared)
}
