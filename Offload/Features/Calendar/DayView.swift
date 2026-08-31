import SwiftUI

/// The Day tab — your schedule as time blocks, one day on screen at a time.
///
/// Two independent swipes, per the redesign: the week strip on top pages **week by week**
/// (Sun–Sat), and the agenda body pages **day by day**. Selecting a day in the strip moves the
/// body; swiping the body moves the strip. Real events and timed tasks render on a real
/// time-grid (`DayTimeGrid`) positioned and sized by their actual clock time, and a task with
/// steps renders as one block subdivided into them rather than as several separate blocks.
///
/// Dragging a block **moves it to the time you drop it at**, snapped to the nearest quarter-hour;
/// only that task changes. What can't be dragged is what this screen doesn't own: a real calendar
/// event belongs to EventKit, and a Gym-linked task mirrors a session scheduled in the Gym tab.
/// All-day and undated work sits in an "Anytime" group below, where there are no coordinates to
/// drop onto, so a drag there means re-sequencing — the same mechanism the wake-up "plan my day"
/// sheet (`DayPlanView`) uses. Everything is theme-aware — the palette adapts light/dark.
struct DayView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var editing: TaskItem?
    @State private var editingEvent: CalendarEvent?
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var now = Date()
    @State private var appeared = false
    @State private var addingTask = false
    /// Flips (not just sets) on every successful reorder drop — `.sensoryFeedback` only fires on
    /// an actual value *change*, so a toggle guarantees each drop re-triggers it regardless of
    /// what the previous value happened to be.
    @State private var didReorder = false
    /// True while a block is being dragged on the grid. Freezes the page `ScrollView` for the
    /// duration so it can't reclaim the pan mid-drag — the long press already stops it *starting*
    /// a scroll, this stops it interrupting one that's underway.
    @State private var isDraggingBlock = false

    private var isToday: Bool { Calendar.current.isDate(selectedDay, inSameDayAs: now) }

    private var density: [Date: DayDensity] {
        DayTimeline.density(tasks: store.allTasks, events: store.rangeEvents)
    }

    /// Selected day's reorderable work — tasks with no fixed commitment (undated, whole-day, or
    /// a soft planner-guessed time). Pinned times and real events aren't here; they're
    /// commitments, not a sequence choice.
    private var flexibleTasksForSelectedDay: [TaskItem] {
        DayTimeline.items(tasks: store.allTasks, events: store.rangeEvents, on: selectedDay)
            .compactMap { item -> TaskItem? in
                guard case let .task(task) = item, !task.isAnchored else { return nil }
                return task
            }
    }

    /// The pageable day range for swiping — a month back, a month ahead. A far date (a meeting
    /// weeks out) is still reachable instantly via the "jump to date" picker in the toolbar, so
    /// the swipeable range doesn't need to cover a year: the previous range (461 days) meant a
    /// `.page`-style `TabView` was building an agenda's full filter/sort/gap-detection pipeline
    /// for hundreds of pages nobody would ever swipe to.
    private var days: [Date] {
        let base = Calendar.current.startOfDay(for: now)
        return (-30...30).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: base) }
    }

    var body: some View {
        // Bucketed once here and handed down, because a `.page`-style `TabView` builds *every*
        // page: `agenda(for:)` asking `DayTimeline.items` for its own day meant the full
        // filter/sort pipeline ran once per page (~49 ms at 100 tasks, ~245 ms at 500) on every
        // render — including every render caused by a task write on some other screen, since the
        // task stream is app-wide. One pass, then 61 dictionary lookups.
        // Protected time renders as ordinary (non-interactive) blocks. Without it the planner just
        // appears to avoid perfectly good empty space for no stated reason — the hours are the
        // whole point of the setting, so they have to be on the schedule you actually look at.
        // Deliberately not folded into `density`: painting the week strip busy on hours you
        // reserved rather than committed would make every day read as full.
        let protectedBlocks = ProtectedTime.stored()
        let protectedEvents = days.flatMap {
            ProtectedTime.busyBlocks(on: $0, blocks: protectedBlocks)
        }
        let itemsByDay = DayTimeline.itemsByDay(tasks: store.allTasks,
                                                events: store.rangeEvents + protectedEvents)
        // Steps get no row of their own — they're drawn *inside* their parent's block. Grouped
        // once here for the same reason as `itemsByDay`: every page of the pager renders.
        let stepsByParent = DayTimeline.stepsByParent(store.allTasks)
        return NavigationStack {
            VStack(spacing: 12) {
                WeekStrip(selected: $selectedDay, density: density, now: now)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .appearIn(0, when: appeared)

                dayPager(itemsByDay, stepsByParent: stepsByParent)
                    .appearIn(1, when: appeared)
            }
            .background(Color.Offload.background)
            .navigationTitle("Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") {
                        withAnimation(Motion.page) { selectedDay = Calendar.current.startOfDay(for: now) }
                    }
                    .font(.Offload.data)
                    .buttonStyle(.pressable)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { addingTask = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Add task on this day")
                }
            }
            .task { await store.observe() }
            .task { await store.loadEvents(around: selectedDay) }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .sensoryFeedback(.impact(weight: .light), trigger: didReorder)
            .onChange(of: selectedDay) { _, day in
                Task { await store.loadEvents(around: day) }
            }
            .sheet(item: $editing) { task in
                NavigationStack { TaskDetailView(task: task) }
            }
            .sheet(item: $editingEvent) { event in
                EventEditView(eventId: event.id) {
                    editingEvent = nil
                    Task { await store.loadEvents(around: selectedDay) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $addingTask) {
                AddTaskSheet(initialDate: isToday ? nil : selectedDay)
            }
        }
    }

    // MARK: Day pager (swipe left/right = previous/next day)

    private func dayPager(_ itemsByDay: [Date: [DayItem]], stepsByParent: [String: [TaskItem]]) -> some View {
        TabView(selection: $selectedDay) {
            ForEach(days, id: \.timeIntervalSince1970) { day in
                ScrollViewReader { proxy in
                    ScrollView {
                        // Keyed by `startOfDay`, not by `day` itself: the pager's dates come from
                        // `date(byAdding: .day)`, which preserves wall-clock time and so lands off
                        // midnight in zones whose DST transition happens at midnight.
                        agenda(for: day, items: itemsByDay[Calendar.current.startOfDay(for: day)] ?? [],
                               stepsByParent: stepsByParent)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 40)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDisabled(isDraggingBlock)
                    // Today opens where you are, not at breakfast. Only today has the anchor, so
                    // this is a no-op on every other page; the guard just saves the wait.
                    .task {
                        guard Calendar.current.isDateInToday(day) else { return }
                        // One beat, so the grid has been laid out and the anchor has a frame to
                        // scroll to. Without it the call lands before layout and does nothing.
                        try? await Task.sleep(for: .milliseconds(120))
                        withAnimation(Motion.settle) {
                            proxy.scrollTo(DayGridMetrics.nowAnchorID, anchor: .center)
                        }
                    }
                }
                .tag(day)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    // MARK: Agenda for one day

    @ViewBuilder
    private func agenda(for day: Date, items: [DayItem], stepsByParent: [String: [TaskItem]]) -> some View {
        let timed = timedEntries(items, stepsByParent: stepsByParent)
        let untimed = items.filter { span($0) == nil }

        VStack(alignment: .leading, spacing: 16) {
            Text(dayHeading(day))
                .font(.Offload.manrope(11, .heavy))
                .tracking(1)
                .foregroundStyle(Color.Offload.teal)

            if items.isEmpty {
                emptyDay
            } else {
                if !timed.isEmpty {
                    if let range = span(of: timed) {
                        Text("\(TimeFormat.time(range.start)) – \(TimeFormat.time(range.end))")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
                    DayTimeGrid(
                        entries: timed,
                        dayStartHour: DayPlanner.storedDayStartHour(),
                        dayEndHour: DayPlanner.storedDayEndHour(),
                        day: day,
                        isDragging: $isDraggingBlock,
                        onMove: handleMove,
                        rowContent: gridBlockContent
                    )
                }

                if !untimed.isEmpty {
                    Text("Anytime")
                        .font(.Offload.manrope(11, .heavy))
                        .tracking(1)
                        .foregroundStyle(Color.Offload.muted)
                        .padding(.top, 4)
                    VStack(spacing: 10) {
                        ForEach(untimed) { item in
                            untimedBlock(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Nothing scheduled today" : "Nothing scheduled")
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.text)
            Text("This day is open.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    // MARK: Blocks

    /// A time-grid block — compact by design, since a block's height is dictated by its real
    /// duration (as little as 15 minutes) rather than however much its content needs, unlike the
    /// old free-flowing agenda card. Left border carries the category accent.
    ///
    /// Interaction here is deliberately all-native and pan-free: a plain tap opens it, a native
    /// drag (`.draggable`, owned by `DayTimeGrid`) moves it to whatever time it's dropped at, and
    /// a long press opens the context menu — which is where Delete lives on this screen. There is
    /// no hand-rolled horizontal swipe, for two compounding reasons: a custom pan gesture on a row
    /// inside a `ScrollView` fights that scroll view for the touch (this screen was the worst
    /// offender — it was nearly unscrollable wherever a block sat under your finger), and a
    /// horizontal swipe here would *also* fight the day pager, whose whole job is horizontal.
    ///
    /// A task with steps renders as one block subdivided into them (`StepLayout` does the
    /// arithmetic), which is the point of the whole change: a step has no time of its own, it has
    /// a share of its parent's. Before this, "Enter REDCap data" (4 hours) sat on the schedule
    /// next to a separate 15-minute block for one of its own steps.
    @ViewBuilder
    private func gridBlockContent(_ entry: TimedEntry) -> some View {
        let accent = self.accent(entry.item)
        let minutes = entry.end.timeIntervalSince(entry.start) / 60
        let slices = StepLayout.slices(parentStart: entry.start,
                                       parentMinutes: Int(minutes.rounded()),
                                       steps: entry.steps)
        // Steps tile whatever the header leaves behind, so the block's own height still equals
        // its duration — the grid positions by time, and the contents must not argue with it.
        let stepRoom = max(0, DayGridMetrics.height(forMinutes: minutes) - Self.blockHeaderHeight)

        let block = VStack(alignment: .leading, spacing: 0) {
            blockHeader(entry, accent: accent, stepsShown: !slices.isEmpty)
            ForEach(slices) { slice in
                stepRow(slice, accent: accent)
                    .frame(height: stepRoom * CGFloat(slice.end.timeIntervalSince(slice.start) / 60 / minutes),
                           alignment: .top)
            }
        }
        // Fill the height `DayTimeGrid` hands over, so a block visibly spans its duration instead
        // of sitting as a fixed-height card at its start time. That's what makes a subdivided
        // block read as one four-hour span containing its steps.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(accent.opacity(0.12))
        // The category stripe is an overlay clipped by the block's own shape, rather than an
        // HStack member, so it runs the block's full height past every step rather than only
        // beside the header.
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3) }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
        .opacity(Self.isProtected(entry.item) ? 0.7 : 1)
        .contentShape(Rectangle())

        // No `.contextMenu` here, deliberately: it and drag-to-move both want the long press, and
        // the menu would win, which is what would leave dragging broken again. Tap opens the task,
        // where Delete and the rest live — one extra tap for actions, in exchange for a drag that
        // works. The "Anytime" list below keeps its menu, since nothing there is draggable by time.
        //
        // Protected time is a constraint rather than a thing, so it takes no tap at all.
        if Self.isProtected(entry.item) {
            block
        } else {
            block.onTapGesture { open(entry.item) }
        }
    }

    /// Reserved hours generated from `ProtectedTime`, rather than anything the user can act on.
    private static func isProtected(_ item: DayItem) -> Bool {
        guard case let .event(event) = item else { return false }
        return ProtectedTime.isProtected(eventId: event.id)
    }

    /// Height reserved for a block's own title and time range, above any steps. Tied to the
    /// grid's minimum block height rather than picked separately, so the shortest block on the
    /// grid is exactly one header — the two can't drift apart and start clipping.
    private static let blockHeaderHeight = DayGridMetrics.minimumBlockHeight

    private func blockHeader(_ entry: TimedEntry, accent: Color, stepsShown: Bool) -> some View {
        HStack(spacing: 8) {
            if case let .task(task) = entry.item {
                Button { Task { await store.toggleComplete(task) } } label: {
                    Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(task.status == "completed" ? Color.Offload.green : accent)
                        .symbolEffect(.bounce, value: task.status)
                }
                .buttonStyle(.pressable(scale: 0.85))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.item.title)
                    .font(.Offload.manrope(13, .bold))
                    .foregroundStyle(Color.Offload.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(TimeFormat.time(entry.start)) – \(TimeFormat.time(entry.end))")
                    // When the block is too short to draw its steps legibly, say how many there
                    // are rather than hiding them entirely — otherwise a task quietly loses the
                    // only sign that it has any.
                    if !stepsShown, !entry.steps.isEmpty {
                        Text("· \(Self.stepsRemaining(entry.steps))/\(entry.steps.count) steps")
                    }
                }
                .font(.system(.caption2))
                .foregroundStyle(Color.Offload.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 11).padding(.trailing, 8)
        .frame(height: Self.blockHeaderHeight, alignment: .center)
    }

    /// One step inside its parent's block: its share of the span, its own start time, and a
    /// checkbox — steps are the thing you actually tick off while the parent's block is running.
    private func stepRow(_ slice: StepLayout.Slice, accent: Color) -> some View {
        let done = slice.task.status == "completed"
        return HStack(spacing: 8) {
            Button { Task { await store.toggleComplete(slice.task) } } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(done ? Color.Offload.green : accent.opacity(0.7))
                    .symbolEffect(.bounce, value: slice.task.status)
            }
            .buttonStyle(.pressable(scale: 0.85))
            Text(slice.task.title)
                .font(.system(.caption2))
                .strikethrough(done)
                .foregroundStyle(done ? Color.Offload.muted : Color.Offload.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(TimeFormat.time(slice.start))
                .font(.system(.caption2))
                .foregroundStyle(Color.Offload.muted)
        }
        .padding(.leading, 20).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(accent.opacity(0.2)).frame(height: 0.5).padding(.leading, 14)
        }
    }

    private static func stepsRemaining(_ steps: [TaskItem]) -> Int {
        steps.filter { $0.status != "completed" }.count
    }

    /// A whole-day event or undated task — no clock, so it reads as an intention, not a block.
    /// Tap to open, long-press for actions (including Delete), same as `gridBlockContent` and for
    /// the same reason: no custom pan gesture on this screen, so scrolling and day-paging stay
    /// entirely the system's to arbitrate.
    private func untimedBlock(_ item: DayItem) -> some View {
        let accent = self.accent(item)
        return HStack(spacing: 10) {
            if case let .task(task) = item {
                Button { Task { await store.toggleComplete(task) } } label: {
                    Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(task.status == "completed" ? Color.Offload.green : accent)
                        .symbolEffect(.bounce, value: task.status)
                }
                .buttonStyle(.pressable(scale: 0.85))
            } else {
                Circle().fill(accent).frame(width: 8, height: 8)
            }
            Text(item.title)
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.text)
            Spacer(minLength: 8)
            Text(item.isEvent ? "All day" : "Planned")
                .font(.Offload.data)
                .foregroundStyle(Color.Offload.muted)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .contextMenu { blockMenu(item) }
        .reorderable(id: item.id, enabled: Self.isFlexibleTask(item), onDrop: handleDrop)
    }

    /// Only a flexible (non-anchored) task is a sequence choice — a real event or a pinned
    /// commitment stays exactly where it is. `static` (no `self` needed) so the nested
    /// `TimedEntry` below — which has no `DayView` instance of its own — can share this exact
    /// rule for the time-grid rather than duplicating it.
    private static func isFlexibleTask(_ item: DayItem) -> Bool {
        guard case let .task(task) = item else { return false }
        return !task.isAnchored
    }

    /// Whose time this screen is allowed to change by dragging. Broader than `isFlexibleTask` on
    /// purpose: a *pinned* task is draggable too, because dragging it is the user re-pinning it,
    /// and a block you can move once but not twice is worse than one you can't move at all. What
    /// stays put is what this screen doesn't own — a real calendar event (EventKit's, not ours)
    /// and a gym-linked task (a mirror of a session scheduled in the Gym tab).
    private static func isMovableTask(_ item: DayItem) -> Bool {
        guard case let .task(task) = item else { return false }
        return task.gymSessionId == nil && task.calendarEventId == nil
    }

    @ViewBuilder
    private func blockMenu(_ item: DayItem) -> some View {
        switch item {
        case let .task(task):
            TaskContextMenu(task: task, onFocus: { FocusTimer.shared.start(task: $0) }, onEdit: { open(.task($0)) })
        case .event:
            Button { open(item) } label: { Label("Edit event", systemImage: "pencil") }
        }
    }

    // MARK: Dragging

    /// A block was dropped at a time on the grid: move that one task there and leave the rest of
    /// the day alone.
    ///
    /// Deliberately *not* a re-plan. The old grid drag routed through `applyReorder`, which
    /// re-ran `DayPlanner.plan` over the whole day, so moving one thing shuffled others the user
    /// hadn't touched — the behaviour that made the screen feel broken rather than merely fiddly.
    /// A hand-placed time is also a commitment, exactly as it is in `AddTaskSheet`: it pins, so
    /// the next "Plan my day" builds around it instead of quietly undoing the drag.
    private func handleMove(id: String, to newStart: Date) {
        // `id` is a row id (`task-<uuid>`), not a task id. Looking a task up by it directly is
        // what made every drag silently do nothing and spring back.
        guard let taskId = DayItem.taskId(fromItemID: id),
              let task = store.allTasks.first(where: { $0.id == taskId }) else { return }
        didReorder.toggle()
        Task { await store.moveTask(task, to: newStart) }
    }

    /// Drop `draggedID` right before `targetID` within the day's flexible tasks, then re-run the
    /// planner with that order and persist whatever times actually changed. Used by the untimed
    /// "Anytime" list, where there are no coordinates to drop onto and sequence is the only thing
    /// a drag can mean — the same mechanism as `DayPlanView`'s `reorder(draggedID:ontoID:)`. The
    /// timed grid above uses `handleMove` instead, since it *has* coordinates.
    private func handleDrop(draggedID: String, ontoID targetID: String) {
        // Both arrive as row ids and have to be translated before they can be matched against
        // task ids — the same mismatch that made this quietly do nothing.
        guard let dragged = DayItem.taskId(fromItemID: draggedID),
              let target = DayItem.taskId(fromItemID: targetID) else { return }
        var order = flexibleTasksForSelectedDay.map(\.id)
        guard let fromIndex = order.firstIndex(of: dragged) else { return }
        order.remove(at: fromIndex)
        guard let toIndex = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: toIndex)
        didReorder.toggle()
        Task { await store.applyReorder(order, on: selectedDay, events: store.rangeEvents) }
    }

    // MARK: Open

    private func open(_ item: DayItem) {
        switch item {
        // A gym-linked task is just this session's schedule block — its real content (exercises,
        // sets, muscle groups) lives only in the Gym tab, so open that instead of task detail.
        case let .task(task) where task.gymSessionId != nil:
            AppNavigation.shared.openGymSession(task.gymSessionId!)
        case let .task(task):   editing = task
        case let .event(event): editingEvent = event
        }
    }

    // MARK: Timing helpers

    /// A timed entry with a resolved start/end, ready to render as a grid block. Conforms to
    /// `DayGridEntry` so `DayTimeGrid` can position, size, and (if it's ours to move) drag it —
    /// see `isMovableTask` for what that excludes.
    private struct TimedEntry: Identifiable, DayGridEntry {
        let item: DayItem
        let start: Date
        let end: Date
        /// This task's steps, which have no time of their own — they divide this block. Empty for
        /// events and for tasks without steps.
        let steps: [TaskItem]
        var id: String { item.id }
        var isDraggable: Bool { DayView.isMovableTask(item) }
    }

    /// The clock span of an item, or nil if it's all-day / undated.
    private func span(_ item: DayItem) -> (start: Date, end: Date)? {
        switch item {
        case let .event(event):
            return event.isAllDay ? nil : (event.start, event.end)
        case let .task(task):
            guard let due = DueDate.parse(task.dueDate), !task.dueIsAllDay else { return nil }
            let minutes = task.effortMinutes ?? 30
            let end = Calendar.current.date(byAdding: .minute, value: minutes, to: due) ?? due
            return (due, end)
        }
    }

    private func timedEntries(_ items: [DayItem], stepsByParent: [String: [TaskItem]]) -> [TimedEntry] {
        items.compactMap { item -> TimedEntry? in
            guard let span = span(item) else { return nil }
            var steps: [TaskItem] = []
            if case let .task(task) = item { steps = stepsByParent[task.id] ?? [] }
            return TimedEntry(item: item, start: span.start, end: span.end, steps: steps)
        }
        .sorted { $0.start < $1.start }
    }

    /// The overall span across all timed entries, for the day's time-range caption.
    private func span(of timed: [TimedEntry]) -> (start: Date, end: Date)? {
        guard let first = timed.first else { return nil }
        let start = timed.map(\.start).min() ?? first.start
        let end = timed.map(\.end).max() ?? first.end
        return (start, end)
    }

    private func accent(_ item: DayItem) -> Color {
        switch item {
        case let .event(event): return event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
        case let .task(task):   return Color.Offload.accent(for: task.category)
        }
    }

    /// Runs once per page the pager builds — 61 times per render — so the formatter comes from
    /// the shared cache rather than being allocated here.
    private func dayHeading(_ day: Date) -> String {
        if Calendar.current.isDate(day, inSameDayAs: now) { return "Today" }
        return CachedDateFormat.string(from: day, pattern: "EEEE, MMM d")
    }
}

#Preview {
    DayView().environment(CaptureCoordinator.shared)
}
