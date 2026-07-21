import SwiftUI

/// The Day tab — your schedule for one day on a single rail: calendar events and timed tasks in
/// the order they'll actually happen. This replaces the old month-grid Calendar and takes over
/// the timeline that used to crowd Home, so Home can stay a light "what needs me" view.
///
/// Everything here is directly actionable: tap an event to edit or delete it in Apple's native
/// editor, tap a task to open it, long-press either for quick actions. Undated "whenever" work
/// lives on Home — this stays a real schedule.
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

    private var items: [DayItem] {
        DayTimeline.items(tasks: store.allTasks, events: store.rangeEvents, on: selectedDay)
    }

    private var density: [Date: DayDensity] {
        DayTimeline.density(tasks: store.allTasks, events: store.rangeEvents)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    WeekStrip(selected: $selectedDay, density: density, now: now)
                        .appearIn(0, when: appeared)
                    timelineCard
                        .appearIn(1, when: appeared)
                        .scrollAppear()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") {
                        withAnimation(Motion.page) { selectedDay = Calendar.current.startOfDay(for: now) }
                    }
                    .font(.Offload.taskTitle)
                    .buttonStyle(.pressable)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button { addingTask = true } label: {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                        .buttonStyle(.pressable(scale: 0.9))
                        .accessibilityLabel("Add task on this day")

                        Button { capture.beginCapture() } label: {
                            Image(systemName: "bolt.circle.fill").font(.title2)
                        }
                        .buttonStyle(.pressable(scale: 0.9))
                        .accessibilityLabel("Quick Capture")
                    }
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

    // MARK: Timeline

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(dayTitle.uppercased(), systemImage: "clock.fill")
                .font(.caption2).fontWeight(.bold)
                .tracking(0.9)
                .foregroundStyle(Color.Offload.teal)

            if items.isEmpty {
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
                            isLast: index == items.count - 1,
                            isPast: (item.time ?? .distantFuture) < now
                        ) {
                            row(item)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private var dayTitle: String {
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

    @ViewBuilder
    private func row(_ item: DayItem) -> some View {
        switch item {
        case let .event(event):
            let tint = event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
            // Tapping a real event opens Apple's native editor — move, rename, or delete in place.
            Button { editingEvent = event } label: {
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
            }
            .buttonStyle(.pressable(scale: 0.99))

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
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.11), in: .rect(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.pressable(scale: 0.99))
            .contextMenu {
                TaskContextMenu(task: task, onFocus: { focusTask = $0 }, onEdit: { editing = $0 })
            }
        }
    }
}

#Preview {
    DayView().environment(CaptureCoordinator.shared)
}
