import SwiftUI

/// The Day tab — your schedule as time blocks, one day on screen at a time.
///
/// Two independent swipes, per the redesign: the week strip on top pages **week by week**
/// (Sun–Sat), and the agenda body pages **day by day**. Selecting a day in the strip moves the
/// body; swiping the body moves the strip. Real events and timed tasks render on a real
/// time-grid (`DayTimeGrid`) positioned and sized by their actual clock time, with any task —
/// including a Gym-linked or pinned one — draggable to any 15-minute slot; all-day and undated
/// work sits in an "Anytime" group below. Everything is theme-aware — the palette adapts
/// light/dark.
struct DayView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var editing: TaskItem?
    @State private var editingEvent: CalendarEvent?
    @State private var focusTask: TaskItem?
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var now = Date()
    @State private var appeared = false
    @State private var addingTask = false
    /// Flips (not just sets) on every successful reorder drop — `.sensoryFeedback` only fires on
    /// an actual value *change*, so a toggle guarantees each drop re-triggers it regardless of
    /// what the previous value happened to be.
    @State private var didReorder = false

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
        NavigationStack {
            VStack(spacing: 12) {
                WeekStrip(selected: $selectedDay, density: density, now: now)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .appearIn(0, when: appeared)

                dayPager
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
            .fullScreenCover(item: $focusTask) { task in
                FocusSessionView(task: task, minutes: task.effortMinutes ?? 25)
            }
        }
    }

    // MARK: Day pager (swipe left/right = previous/next day)

    private var dayPager: some View {
        TabView(selection: $selectedDay) {
            ForEach(days, id: \.timeIntervalSince1970) { day in
                ScrollView {
                    agenda(for: day)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .tag(day)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    // MARK: Agenda for one day

    @ViewBuilder
    private func agenda(for day: Date) -> some View {
        let items = DayTimeline.items(tasks: store.allTasks, events: store.rangeEvents, on: day)
        let timed = timedEntries(items)
        let untimed = items.filter { span($0) == nil }

        VStack(alignment: .leading, spacing: 16) {
            Text(dayHeading(day).uppercased())
                .font(.Offload.manrope(11, .heavy))
                .tracking(1)
                .foregroundStyle(Color.Offload.teal)

            if items.isEmpty {
                emptyDay
            } else {
                if !timed.isEmpty {
                    if let range = span(of: timed) {
                        Text("\(CalendarView.time(range.start)) – \(CalendarView.time(range.end))")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
                    DayTimeGrid(
                        entries: timed,
                        dayStartHour: DayPlanner.storedDayStartHour(),
                        dayEndHour: DayPlanner.storedDayEndHour(),
                        day: day,
                        onReschedule: { entry, newStart in
                            guard case let .task(task) = entry.item else { return }
                            didReorder.toggle()
                            Task { await store.reschedule(task, to: newStart) }
                        },
                        rowContent: gridBlockContent
                    )
                }

                if !untimed.isEmpty {
                    Text("ANYTIME")
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
    /// Deliberately not a `Button`: a `Button`'s tap recognition is a separate, opaque gesture
    /// recognizer that can't know a sibling drag gesture (the grid's long-press-reschedule, or
    /// `.swipeToDelete`'s own swipe) already decided the same touch was something else — which
    /// is exactly how a completed drag-to-reschedule, or a completed swipe, could *also* open
    /// this row's detail sheet. `.swipeToDelete(onTap:onDelete:)` now owns tap-vs-swipe itself
    /// from a single gesture, so there's nothing left to race against.
    private func gridBlockContent(_ entry: TimedEntry) -> some View {
        let accent = self.accent(entry.item)
        return HStack(spacing: 8) {
            Rectangle().fill(accent).frame(width: 3)
            if case let .task(task) = entry.item {
                Button { Task { await store.toggleComplete(task) } } label: {
                    Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
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
                Text("\(CalendarView.time(entry.start)) – \(CalendarView.time(entry.end))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.Offload.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
        .contentShape(Rectangle())
        .contextMenu { blockMenu(entry.item) }
        .swipeToDelete(ifTask: entry.item, onTap: { open(entry.item) }) { task in Task { await store.delete(task) } }
    }

    /// A whole-day event or undated task — no clock, so it reads as an intention, not a block.
    /// Not a `Button`, same reasoning as `gridBlockContent`: `.swipeToDelete(onTap:onDelete:)`
    /// owns the tap so it can't race the swipe gesture.
    private func untimedBlock(_ item: DayItem) -> some View {
        let accent = self.accent(item)
        return HStack(spacing: 10) {
            if case let .task(task) = item {
                Button { Task { await store.toggleComplete(task) } } label: {
                    Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
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
        .contextMenu { blockMenu(item) }
        .swipeToDelete(ifTask: item, onTap: { open(item) }) { task in Task { await store.delete(task) } }
        .reorderable(id: item.id, enabled: isFlexibleTask(item), onDrop: handleDrop)
    }

    /// Only a flexible (non-anchored) task is a sequence choice — a real event or a pinned
    /// commitment stays exactly where it is.
    private func isFlexibleTask(_ item: DayItem) -> Bool {
        guard case let .task(task) = item else { return false }
        return !task.isAnchored
    }

    @ViewBuilder
    private func blockMenu(_ item: DayItem) -> some View {
        switch item {
        case let .task(task):
            TaskContextMenu(task: task, onFocus: { focusTask = $0 }, onEdit: { open(.task($0)) })
        case .event:
            Button { open(item) } label: { Label("Edit event", systemImage: "pencil") }
        }
    }

    // MARK: Drag-to-reorder

    /// Drop `draggedID` right before `targetID` within the day's flexible tasks, then re-run the
    /// planner with that order and persist whatever times actually changed. Native long-press-
    /// and-drag (`.draggable`/`.dropDestination`) rather than a hand-built gesture — it already
    /// knows how to not fight scrolling or tapping, which a raw `DragGesture` doesn't for free.
    private func handleDrop(draggedID: String, ontoID targetID: String) {
        var order = flexibleTasksForSelectedDay.map(\.id)
        guard let fromIndex = order.firstIndex(of: draggedID) else { return }
        order.remove(at: fromIndex)
        guard let toIndex = order.firstIndex(of: targetID) else { return }
        order.insert(draggedID, at: toIndex)
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
    /// `DayGridEntry` so `DayTimeGrid` can position, size, and drag it. Any task — including a
    /// Gym-linked or otherwise pinned one — is draggable; only a real calendar event isn't
    /// (rescheduling one of those would need writing back to EventKit, a different feature).
    private struct TimedEntry: Identifiable, DayGridEntry {
        let item: DayItem
        let start: Date
        let end: Date
        var id: String { item.id }
        var isDraggable: Bool {
            if case .task = item { return true }
            return false
        }
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

    private func timedEntries(_ items: [DayItem]) -> [TimedEntry] {
        items.compactMap { item in span(item).map { TimedEntry(item: item, start: $0.start, end: $0.end) } }
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

    private func dayHeading(_ day: Date) -> String {
        if Calendar.current.isDate(day, inSameDayAs: now) { return "Today" }
        let df = DateFormatter(); df.dateFormat = "EEEE, MMM d"
        return df.string(from: day)
    }
}

private extension View {
    /// Swipe-to-delete for a `DayItem` block — only tasks are deletable this way; a real
    /// calendar event is edited/deleted through its own native editor instead. `onTap` still
    /// applies to both: a task gets it via `.swipeToDelete`'s own race-free tap ownership, and
    /// an event — which has no competing drag gesture to race against here — just gets a plain
    /// tap gesture.
    @ViewBuilder
    func swipeToDelete(ifTask item: DayItem, onTap: @escaping () -> Void, delete: @escaping (TaskItem) -> Void) -> some View {
        if case let .task(task) = item {
            self.swipeToDelete(onTap: onTap) { delete(task) }
        } else {
            self.onTapGesture(perform: onTap)
        }
    }
}

#Preview {
    DayView().environment(CaptureCoordinator.shared)
}
