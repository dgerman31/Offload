import SwiftUI

/// Home — your whole day in one place (spec §5.4 + Design Language 2.0).
///
/// Reads top to bottom the way a day actually runs: a hero that says what needs you, a week
/// strip to look ahead, then the selected day as a *timeline* — calendar events and due tasks
/// on one rail, colour-coded by category, in the order they'll happen. Below that: what's
/// overdue, a time-boxed batch, and the undated "whenever" pile.
///
/// For a cognitive-offload app an empty Home is a *result*, so the clear state reads as a
/// reward rather than a blank list.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var editing: TaskItem?
    @State private var batchMinutes: Int?
    @State private var now = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var appeared = false
    @State private var addingTask = false
    @State private var planningDay = false
    @State private var focusTask: TaskItem?
    @State private var activeRitual: RitualView.Mode?
    private var patterns: PatternService { PatternService.shared }

    private var isToday: Bool { Calendar.current.isDate(selectedDay, inSameDayAs: now) }

    private var summary: DaySummary {
        DayDashboard.summary(tasks: store.allTasks, events: store.todayEvents, now: now)
    }

    private var dayItems: [DayItem] {
        DayTimeline.items(tasks: store.allTasks, events: store.rangeEvents, on: selectedDay)
    }

    private var density: [Date: DayDensity] {
        DayTimeline.density(tasks: store.allTasks, events: store.rangeEvents)
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

    /// Open tasks with no due date — kept out of the timeline so it stays a real schedule.
    private var unscheduled: [TaskItem] {
        HomeGrouping.inDisplayOrder(store.openTasks.filter { DueDate.parse($0.dueDate) == nil })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroCard.appearIn(0, when: appeared)

                    if isToday, !summary.isClear || summary.nextTask != nil {
                        nowAndNext.appearIn(2, when: appeared).scrollAppear()
                    }
                    if isToday, showPlanPrompt {
                        planDayCard.appearIn(2, when: appeared).scrollAppear()
                    }
                    if isToday, let ritual = suggestedRitual {
                        ritualCard(ritual).appearIn(3, when: appeared).scrollAppear()
                    }
                    if isToday, load.openLoops > 0 {
                        mentalLoadCard.appearIn(4, when: appeared).scrollAppear()
                    }
                    if !patterns.suggestions.isEmpty {
                        suggestionsCard.appearIn(3, when: appeared).scrollAppear()
                    }
                    if isToday, !overdueTasks.isEmpty {
                        overdueCard.appearIn(4, when: appeared).scrollAppear()
                    }
                    // The day's schedule now lives in the Day tab — Home stays a light
                    // "what needs me" view rather than a full timeline rail.
                    if isToday {
                        gotTimeCard.appearIn(6, when: appeared).scrollAppear()
                        if !unscheduled.isEmpty {
                            unscheduledCard.appearIn(7, when: appeared).scrollAppear()
                        }
                    }
                    if store.openTasks.isEmpty && summary.completedToday == 0 {
                        EmptyCaptureInvitation { capture.beginCapture() }
                            .padding(.top, 20)
                            .appearIn(2, when: appeared)
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
            .task { await store.loadEvents(around: selectedDay) }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    withAnimation(Motion.standard) { now = Date() }
                }
            }
            .onChange(of: selectedDay) { _, day in
                Task { await store.loadEvents(around: day) }
            }
            // Keep reminders matched to whatever just changed.
            .onChange(of: store.allTasks.count) { _, _ in
                Task { await NotificationSync.shared.refresh() }
            }
            .sheet(item: $editing) { task in
                NavigationStack { TaskDetailView(task: task) }
            }
            .sheet(isPresented: $addingTask) {
                AddTaskSheet(initialDate: isToday ? nil : selectedDay)
            }
            .sheet(isPresented: $planningDay) {
                DayPlanView(tasks: store.allTasks, events: store.rangeEvents, day: now) {
                    Task { await NotificationSync.shared.refresh() }
                }
            }
            .fullScreenCover(item: $focusTask) { task in
                FocusSessionView(task: task, minutes: task.effortMinutes ?? 25)
            }
            .sheet(item: $activeRitual) { mode in
                RitualView(mode: mode, tasks: store.allTasks, events: store.rangeEvents) {
                    planningDay = true
                }
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

    private struct HeroChip { let text: String; let icon: String }

    private func heroChips(_ s: DaySummary) -> [HeroChip] {
        var chips: [HeroChip] = []
        if s.overdueCount > 0 { chips.append(.init(text: "\(s.overdueCount) overdue", icon: "exclamationmark.triangle.fill")) }
        if s.dueTodayCount > 0 { chips.append(.init(text: "\(s.dueTodayCount) due", icon: "checklist")) }
        if s.eventCount > 0 { chips.append(.init(text: "\(s.eventCount) event\(s.eventCount == 1 ? "" : "s")", icon: "calendar")) }
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

    // MARK: Plan my day

    /// Anything the planner could actually place — undated work, whole-day intentions, and
    /// overdue items. Previously this only counted strictly undated tasks, so captured work
    /// (which nearly always got *some* date) never triggered the prompt.
    private var plannableTasks: [TaskItem] {
        DayPlanner.candidates(from: store.allTasks, on: now, now: now)
    }

    private var showPlanPrompt: Bool { !plannableTasks.isEmpty }

    private var planDayCard: some View {
        Button { planningDay = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x8A6FE0)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan my day")
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    Text(planPromptSubtitle)
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Offload.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offloadCard()
        }
        .buttonStyle(.pressable(scale: 0.99))
    }

    private var planPromptSubtitle: String {
        let loose = plannableTasks.count
        return "Fit \(loose) loose task\(loose == 1 ? "" : "s") into your free time"
    }

    // MARK: Rituals

    /// Offer the brief early and the shutdown late — a ritual prompt at the wrong hour is
    /// just noise, so this appears only when it's actually the right moment.
    private var suggestedRitual: RitualView.Mode? {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<11:  return .morning
        case 19..<24: return .evening
        default:      return nil
        }
    }

    private func ritualCard(_ mode: RitualView.Mode) -> some View {
        Button { activeRitual = mode } label: {
            HStack(spacing: 14) {
                Image(systemName: mode == .morning ? "sun.horizon.fill" : "moon.stars.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: mode.accentColors,
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .morning ? "Morning brief" : "Close the day")
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    Text(mode == .morning
                         ? "See the shape of today in one place"
                         : "Review, park what's left, empty your head")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Offload.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offloadCard()
        }
        .buttonStyle(.pressable(scale: 0.99))
    }

    // MARK: Mental load

    private var load: MentalLoad {
        MentalLoad.compute(tasks: store.allTasks, now: now)
    }

    /// An inverse health ring: the honest headline for an app whose promise is that you get to
    /// stop carrying things. Lower is calmer.
    private var mentalLoadCard: some View {
        let l = load
        let tint = loadTint(l.band)
        return card("Mental load", icon: l.band.symbol, tint: tint) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(tint.opacity(0.18), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: max(0.02, Double(l.score) / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Motion.settle, value: l.score)
                    Text("\(l.score)")
                        .font(.system(.callout, design: .rounded)).fontWeight(.bold)
                        .foregroundStyle(Color.Offload.text)
                        .contentTransition(.numericText(value: Double(l.score)))
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text(l.headline)
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(l.advice)
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func loadTint(_ band: MentalLoad.Band) -> Color {
        switch band {
        case .clear: return Color.Offload.green
        case .light: return Color.Offload.teal
        case .full:  return Color.Offload.amber
        case .heavy: return Color.Offload.red
        }
    }

    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 9, style: .continuous))
    }

    // MARK: Timeline

    /// For today, the timeline is *liquid*: soft-scheduled work reflows around now and the
    /// day's fixed points, so nothing rots into "overdue" the moment it runs long. Other days
    /// render statically — there's no "now" to heal against.
    private var displayedTimelineItems: [DayItem] { isToday ? todayTimelineItems : dayItems }

    private var timelineCard: some View {
        let items = displayedTimelineItems
        let healed = isToday ? healedToday : LiquidTimeline.Result()
        return card(timelineTitle, icon: "clock.fill", tint: Color.Offload.teal) {
            VStack(spacing: 12) {
                if isToday && healed.isHealing { driftBanner(healed) }

                if items.isEmpty && healed.spilled.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isToday ? "Nothing scheduled today" : "Nothing scheduled")
                            .font(.Offload.taskTitle)
                            .foregroundStyle(Color.Offload.text)
                        Text("This day is open.")
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            TimelineRow(
                                accent: accent(for: item),
                                isFirst: index == 0,
                                isLast: index == items.count - 1 && healed.spilled.isEmpty,
                                isPast: (item.time ?? .distantFuture) < now
                            ) {
                                timelineCardBody(item)
                            }
                        }
                    }
                }

                if isToday && !healed.spilled.isEmpty { spilledSection(healed.spilled) }
            }
        }
    }

    /// Honest headline when the day has slipped, with one tap to bank the new times so
    /// reminders follow.
    private func driftBanner(_ healed: LiquidTimeline.Result) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .foregroundStyle(Color.Offload.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(healed.spilled.isEmpty
                     ? "Running \(DayPlanner.formatted(healed.behindMinutes)) behind"
                     : "The day's overfull")
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text(healed.spilled.isEmpty
                     ? "Timeline adjusted to fit what's left."
                     : "\(healed.spilled.count) won't fit — reflowed the rest.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer(minLength: 0)
            Button {
                Task { await store.commitReflow(healed.placed) }
            } label: {
                Text("Save times")
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.Offload.amber.opacity(0.16), in: .capsule)
                    .foregroundStyle(Color.Offload.amber)
            }
            .buttonStyle(.pressable)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.amber.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func spilledSection(_ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Won't fit today", systemImage: "tray.full.fill")
                .font(.caption2).fontWeight(.bold).tracking(0.6)
                .foregroundStyle(Color.Offload.muted)
            ForEach(tasks) { task in
                Button { editing = task } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Color.Offload.accent(for: task.category)).frame(width: 6, height: 6)
                        Text(task.title)
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            Task { await store.snooze(task, .tomorrow) }
                        } label: {
                            Text("Tomorrow")
                                .font(.caption2).fontWeight(.semibold)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                                .foregroundStyle(Color.Offload.indigo)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .buttonStyle(.pressable(scale: 0.99))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var timelineTitle: String {
        if isToday { return "Today" }
        let df = DateFormatter(); df.dateFormat = "EEEE, MMM d"
        return df.string(from: selectedDay)
    }

    private func accent(for item: DayItem) -> Color {
        switch item {
        case let .event(event): return event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
        case let .task(task):   return Color.Offload.accent(for: task.category)
        }
    }

    // MARK: Self-healing timeline

    /// Immovable points today: real events and anchored (pinned) tasks.
    private var todayAnchors: [LiquidTimeline.Anchor] {
        let cal = Calendar.current
        var anchors = store.rangeEvents
            .filter { !$0.isAllDay && cal.isDate($0.start, inSameDayAs: now) }
            .map { LiquidTimeline.Anchor(start: $0.start, end: $0.end) }
        for task in store.openTasks where task.isAnchored {
            guard let start = DueDate.parse(task.dueDate), cal.isDate(start, inSameDayAs: now) else { continue }
            let mins = task.effortMinutes ?? EnergyBatch.defaultEffort
            anchors.append(.init(start: start, end: cal.date(byAdding: .minute, value: mins, to: start) ?? start))
        }
        return anchors
    }

    /// Today's flexible work — everything due today that isn't a fixed anchor, whether it has a
    /// soft time or is all-day (a "gym today"). The healer flows all of it into free time.
    private var todaySoftTasks: [TaskItem] {
        let cal = Calendar.current
        return store.openTasks.filter { task in
            guard !task.isAnchored, let due = DueDate.parse(task.dueDate) else { return false }
            return cal.isDate(due, inSameDayAs: now)
        }
    }

    private var healedToday: LiquidTimeline.Result {
        LiquidTimeline.heal(softTasks: todaySoftTasks, anchors: todayAnchors, now: now)
    }

    /// Minutes-of-drift per task id, for the "moved" annotation on a reflowed row.
    private var driftByTaskID: [String: Int] {
        Dictionary(healedToday.placed.map { ($0.task.id, $0.driftMinutes) }, uniquingKeysWith: { a, _ in a })
    }

    /// Today's timeline items with soft tasks shown at their *projected* times: events and
    /// anchored tasks at their fixed times, plus each reflowed soft task as a copy carrying the
    /// projected time so the existing row rendering just works. Spilled tasks are handled apart.
    private var todayTimelineItems: [DayItem] {
        let cal = Calendar.current
        let ownEventIDs = Set(store.allTasks.compactMap(\.calendarEventId))
        var items: [DayItem] = store.rangeEvents
            .filter { !$0.isAllDay && cal.isDate($0.start, inSameDayAs: now) && !ownEventIDs.contains($0.id) }
            .map { .event($0) }
        for task in store.openTasks where task.isAnchored {
            if DueDate.parse(task.dueDate).map({ cal.isDate($0, inSameDayAs: now) }) ?? false {
                items.append(.task(task))
            }
        }
        for placed in healedToday.placed {
            var copy = placed.task
            copy.dueDate = DueDate.canonicalString(from: placed.start)
            copy.dueIsAllDay = false
            items.append(.task(copy))
        }
        return DayTimeline.ordered(items)
    }

    /// A soft tinted card per entry — the colour-blocked look from the reference.
    @ViewBuilder
    private func timelineCardBody(_ item: DayItem) -> some View {
        switch item {
        case let .event(event):
            let tint = event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    Spacer(minLength: 8)
                    Text(event.isAllDay ? "All day" : CalendarView.time(event.start))
                        .font(.Offload.data)
                        .foregroundStyle(tint)
                        .lineLimit(1).fixedSize()
                }
                if let location = event.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(Color.Offload.muted)
                        .lineLimit(1)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.13), in: .rect(cornerRadius: 14, style: .continuous))

        case let .task(task):
            let tint = Color.Offload.accent(for: task.category)
            Button { editing = task } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            Task { await store.toggleComplete(task) }
                        } label: {
                            Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(task.status == "completed" ? Color.Offload.green : tint)
                                .symbolEffect(.bounce, value: task.status)
                        }
                        .buttonStyle(.pressable(scale: 0.85))

                        Text(task.title)
                            .font(.Offload.taskTitle)
                            .foregroundStyle(Color.Offload.text)
                            .strikethrough(task.status == "completed", color: Color.Offload.muted)
                        Spacer(minLength: 8)
                        // Whole-day work has no clock time to show — saying "12:00 AM" would
                        // be both wrong and alarming.
                        if let due = DueDate.parse(task.dueDate), !task.dueIsAllDay {
                            Text(CalendarView.time(due))
                                .font(.Offload.data)
                                .foregroundStyle(tint)
                                .lineLimit(1).fixedSize()
                        } else if task.dueIsAllDay {
                            Text("Anytime")
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    if let details = task.descriptionText, !details.isEmpty {
                        Text(details)
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.muted)
                            .lineLimit(2)
                            .padding(.leading, 24)
                    }
                    if task.status == "in_progress" {
                        Label("In progress", systemImage: "circle.lefthalf.filled")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(tint)
                            .padding(.leading, 24)
                    }
                    // The liquid tell: this soft task slid later because the day ran long.
                    if isToday, let drift = driftByTaskID[task.id], drift >= LiquidTimeline.driftThreshold {
                        Label("moved \(DayPlanner.formatted(drift)) later", systemImage: "arrow.down")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(Color.Offload.amber)
                            .padding(.leading, 24)
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.11), in: .rect(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.pressable(scale: 0.99))
            .contextMenu { taskMenu(task) }
        }
    }

    /// Long-press actions come from the single shared definition, so what you can do to a task
    /// never depends on which screen you found it on.
    @ViewBuilder
    private func taskMenu(_ task: TaskItem) -> some View {
        TaskContextMenu(task: task, onFocus: { focusTask = $0 }, onEdit: { editing = $0 })
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
                            withAnimation(Motion.standard) { batchMinutes = selected ? nil : minutes }
                            Haptics.light()
                        } label: {
                            Text("\(minutes)m")
                                .font(.caption).fontWeight(.semibold)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(selected ? Color.Offload.indigo : Color.Offload.muted.opacity(0.12),
                                            in: .capsule)
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
        .contextMenu { taskMenu(task) }
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
