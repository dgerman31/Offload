import SwiftUI

/// The Day tab — your schedule as time blocks, one day on screen at a time.
///
/// Two independent swipes, per the redesign: the week strip on top pages **week by week**
/// (Sun–Sat), and the agenda body pages **day by day**. Selecting a day in the strip moves the
/// body; swiping the body moves the strip. Real events and timed tasks render as colour-blocked
/// time ranges with gaps shown as breaks; all-day and undated work sits in an "Anytime" group
/// below. Everything is theme-aware — the layout is the mockup's, the palette adapts light/dark.
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
                    VStack(spacing: 10) {
                        ForEach(Array(timed.enumerated()), id: \.element.item.id) { index, entry in
                            if index > 0, let gap = gap(timed[index - 1], entry) {
                                breakBlock(from: gap.start, to: gap.end)
                            }
                            timeBlock(entry)
                        }
                    }
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

    /// A colour-blocked time range — the mockup's event/task card, adapted to the app's surface
    /// tokens so it reads in light or dark. Left border carries the category accent.
    private func timeBlock(_ entry: TimedEntry) -> some View {
        let accent = self.accent(entry.item)
        return Button { open(entry.item) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(CalendarView.time(entry.start)) – \(CalendarView.time(entry.end))")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                        Spacer(minLength: 0)
                        if case let .task(task) = entry.item {
                            Button { Task { await store.toggleComplete(task) } } label: {
                                Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(task.status == "completed" ? Color.Offload.green : accent)
                                    .symbolEffect(.bounce, value: task.status)
                            }
                            .buttonStyle(.pressable(scale: 0.85))
                        }
                    }
                    Text(entry.item.title)
                        .font(.Offload.manrope(15, .bold))
                        .foregroundStyle(Color.Offload.text)
                        .multilineTextAlignment(.leading)
                    if let location = location(entry.item) {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Color.Offload.muted)
                            .lineLimit(1)
                    }
                    if let people = people(entry.item), !people.isEmpty {
                        avatars(people)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.Offload.surface, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.Offload.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.pressable(scale: 0.99))
        .contextMenu { blockMenu(entry.item) }
        .swipeToDelete(ifTask: entry.item) { task in Task { await store.delete(task) } }
        .reorderable(entry.item, onDrop: handleDrop)
    }

    /// A whole-day event or undated task — no clock, so it reads as an intention, not a block.
    private func untimedBlock(_ item: DayItem) -> some View {
        let accent = self.accent(item)
        return Button { open(item) } label: {
            HStack(spacing: 10) {
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
        }
        .buttonStyle(.pressable(scale: 0.99))
        .contextMenu { blockMenu(item) }
        .swipeToDelete(ifTask: item) { task in Task { await store.delete(task) } }
        .reorderable(item, onDrop: handleDrop)
    }

    private func breakBlock(from start: Date, to end: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Offload.muted)
            Text("Free")
                .font(.Offload.manrope(11, .semibold))
                .foregroundStyle(Color.Offload.muted)
            Text("\(CalendarView.time(start)) – \(CalendarView.time(end))")
                .font(.Offload.data)
                .foregroundStyle(Color.Offload.muted.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.Offload.divider)
        )
    }

    private func avatars(_ names: [String]) -> some View {
        HStack(spacing: -6) {
            ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { index, name in
                let color = Self.avatarColors[index % Self.avatarColors.count]
                Text(initial(name))
                    .font(.Offload.manrope(10, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color, in: Circle())
                    .overlay(Circle().strokeBorder(Color.Offload.surface, lineWidth: 1.5))
            }
        }
        .padding(.top, 2)
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
        Haptics.light()
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

    /// A timed entry with a resolved start/end, ready to render as a block.
    private struct TimedEntry { let item: DayItem; let start: Date; let end: Date }

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

    /// A free gap between two consecutive blocks, if it's at least 20 minutes and non-overlapping.
    private func gap(_ a: TimedEntry, _ b: TimedEntry) -> (start: Date, end: Date)? {
        guard b.start.timeIntervalSince(a.end) >= 20 * 60 else { return nil }
        return (a.end, b.start)
    }

    private func accent(_ item: DayItem) -> Color {
        switch item {
        case let .event(event): return event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
        case let .task(task):   return Color.Offload.accent(for: task.category)
        }
    }

    private func location(_ item: DayItem) -> String? {
        if case let .event(event) = item { return event.location }
        return nil
    }

    private func people(_ item: DayItem) -> [String]? {
        if case let .task(task) = item { return People.decode(task.people) }
        return nil
    }

    private func initial(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private func dayHeading(_ day: Date) -> String {
        if Calendar.current.isDate(day, inSameDayAs: now) { return "Today" }
        let df = DateFormatter(); df.dateFormat = "EEEE, MMM d"
        return df.string(from: day)
    }

    private static let avatarColors: [Color] = [
        Color(hex: 0x7A5AE0), Color(hex: 0xE8547C), Color(hex: 0xD79A2B),
        Color(hex: 0x2E8BC9), Color(hex: 0x18A97F), Color(hex: 0x4C6FE7)
    ]
}

private extension View {
    /// Swipe-to-delete for a `DayItem` block — only tasks are deletable this way; a real
    /// calendar event is edited/deleted through its own native editor instead.
    @ViewBuilder
    func swipeToDelete(ifTask item: DayItem, delete: @escaping (TaskItem) -> Void) -> some View {
        if case let .task(task) = item {
            self.swipeToDelete { delete(task) }
        } else {
            self
        }
    }

    /// Long-press and drag to reorder — only for a day's flexible tasks (not anchored/pinned
    /// ones, not real events, which aren't a sequence choice). Native `.draggable`/
    /// `.dropDestination` rather than a hand-rolled position-tracking gesture: it already knows
    /// how to coexist with scrolling and tapping without any extra work here.
    @ViewBuilder
    func reorderable(_ item: DayItem, onDrop: @escaping (_ draggedID: String, _ targetID: String) -> Void) -> some View {
        if case let .task(task) = item, !task.isAnchored {
            self
                .draggable(task.id)
                .dropDestination(for: String.self) { items, _ in
                    guard let draggedID = items.first, draggedID != task.id else { return }
                    onDrop(draggedID, task.id)
                }
        } else {
            self
        }
    }
}

#Preview {
    DayView().environment(CaptureCoordinator.shared)
}
