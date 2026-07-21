import SwiftUI

/// The Calendar tab: a month grid you can tap into, with the selected day's real timeline
/// below — calendar events and due tasks merged in the order they'll actually happen.
/// Swipe left/right on the grid to change months.
///
/// Motion: months slide in from the direction you moved, the selection puck travels between
/// days via `matchedGeometryEffect`, and timeline rows fade under the scroll.
struct CalendarView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = CalendarStore()
    @State private var editing: TaskItem?
    @State private var editingEvent: CalendarEvent?
    @State private var appeared = false
    @State private var addingTask = false
    @Namespace private var selectionNamespace

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    calendarPanel
                        .appearIn(0, when: appeared)
                    dayDetail
                        .appearIn(1, when: appeared)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") { withAnimation(Motion.page) { store.goToToday() } }
                        .font(.Offload.taskTitle)
                        .buttonStyle(.pressable)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        // Adds straight onto the day you're looking at.
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
            .task { await store.observeTasks() }
            .task { await store.loadEvents() }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .sheet(item: $editing) { task in
                NavigationStack { TaskDetailView(task: task) }
            }
            // Tapping a real calendar event opens Apple's native editor (move / rename / delete).
            // On dismiss we reload so the timeline reflects whatever the user just changed.
            .sheet(item: $editingEvent) { event in
                EventEditView(eventId: event.id) {
                    editingEvent = nil
                    Task { await store.loadEvents() }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $addingTask) {
                AddTaskSheet(initialDate: store.selectedDate)
            }
        }
    }

    // MARK: Calendar panel

    private var calendarPanel: some View {
        VStack(spacing: 16) {
            monthHeader
            weekdayHeader
            monthGrid
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .offloadCard(cornerRadius: 24, elevation: .medium)
    }

    private var monthHeader: some View {
        HStack {
            monthButton("chevron.left", label: "Previous month") { store.moveMonth(by: -1) }
            Spacer()
            Text(store.monthTitle)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(Color.Offload.text)
                .contentTransition(.opacity)
                .animation(Motion.page, value: store.monthTitle)
            Spacer()
            monthButton("chevron.right", label: "Next month") { store.moveMonth(by: 1) }
        }
        .padding(.horizontal, 6)
    }

    private func monthButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.page) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.Offload.indigo)
                .frame(width: 34, height: 34)
                .background(Color.Offload.indigo.opacity(0.10), in: .circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(label)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.caption2).fontWeight(.bold)
                    .tracking(0.6)
                    .foregroundStyle(Color.Offload.muted.opacity(0.8))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: Grid

    private var monthGrid: some View {
        let density = store.densityByDay
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(store.gridDays, id: \.timeIntervalSince1970) { day in
                dayCell(day, density: density[Calendar.current.startOfDay(for: day)] ?? DayDensity())
            }
        }
        .padding(.horizontal, 6)
        .id(store.visibleMonth)
        .transition(monthTransition)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    withAnimation(Motion.page) {
                        if value.translation.width < -40 { store.moveMonth(by: 1) }
                        else if value.translation.width > 40 { store.moveMonth(by: -1) }
                    }
                }
        )
    }

    /// Slide in from whichever side matches the direction of travel.
    private var monthTransition: AnyTransition {
        let forward = store.lastMoveDirection >= 0
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func dayCell(_ day: Date, density: DayDensity) -> some View {
        let selected = store.isSelected(day)
        let today = store.isToday(day)
        let inMonth = store.isInVisibleMonth(day)

        return Button {
            withAnimation(Motion.quick) { store.select(day) }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    // The selection puck travels between days instead of blinking on/off.
                    if selected {
                        Circle()
                            .fill(
                                LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x3B4CB8)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                            // Scoped per month so the outgoing and incoming grids during a
                            // month transition never claim the same geometry group.
                            .matchedGeometryEffect(
                                id: "selectedDay-\(Calendar.current.component(.month, from: store.visibleMonth))",
                                in: selectionNamespace
                            )
                            .elevated(.low)
                    } else if today {
                        Circle().strokeBorder(Color.Offload.indigo.opacity(0.55), lineWidth: 1.5)
                    }
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(.callout, design: .rounded))
                        .fontWeight(today || selected ? .bold : .medium)
                        .foregroundStyle(dayNumberColor(selected: selected, today: today, inMonth: inMonth))
                }
                .frame(width: 34, height: 34)

                // Density dots: one per kind, so a glance shows "busy with what".
                HStack(spacing: 3) {
                    if density.events > 0 {
                        Circle().fill(Color.Offload.teal).frame(width: 5, height: 5)
                    }
                    if density.tasks > 0 {
                        Circle()
                            .fill(density.hasHighPriority ? Color.Offload.red : Color.Offload.indigo)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
                .opacity(inMonth ? 1 : 0.3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(accessibilityLabel(day, density: density, selected: selected, today: today))
    }

    private func dayNumberColor(selected: Bool, today: Bool, inMonth: Bool) -> Color {
        if selected { return .white }
        if today { return Color.Offload.indigo }
        return inMonth ? Color.Offload.text : Color.Offload.muted.opacity(0.45)
    }

    private func accessibilityLabel(_ day: Date, density: DayDensity, selected: Bool, today: Bool) -> String {
        let df = DateFormatter(); df.dateStyle = .full
        var parts = [df.string(from: day)]
        if today { parts.append("today") }
        if density.events > 0 { parts.append("\(density.events) event\(density.events == 1 ? "" : "s")") }
        if density.tasks > 0 { parts.append("\(density.tasks) task\(density.tasks == 1 ? "" : "s")") }
        if density.isEmpty { parts.append("nothing scheduled") }
        if selected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    // MARK: Selected day

    private var dayDetail: some View {
        let items = store.selectedDayItems
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDayTitle)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.Offload.text)
                    .contentTransition(.opacity)
                Spacer()
                if store.loadingEvents {
                    ProgressView().controlSize(.small)
                } else if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Color.Offload.muted)
                        .contentTransition(.numericText(value: Double(items.count)))
                }
            }
            .animation(Motion.standard, value: selectedDayTitle)

            if !store.calendarAccess {
                Label("Turn on calendar access to see your events here.", systemImage: "calendar.badge.exclamationmark")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offloadCard()
            }

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing scheduled")
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    Text("This day is open.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .offloadCard()
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        timelineRow(item).scrollAppear(scale: 0.97, lift: 10)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: store.selectedDate)
    }

    private var selectedDayTitle: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        return df.string(from: store.selectedDate)
    }

    @ViewBuilder
    private func timelineRow(_ item: DayItem) -> some View {
        switch item {
        case let .event(event):
            // Real calendar events are now tappable — tapping opens the native editor so they can
            // be moved, renamed, or deleted, just like tasks are editable via their detail sheet.
            Button { editingEvent = event } label: { eventRow(event) }
                .buttonStyle(.pressable(scale: 0.98))
                .accessibilityHint("Opens the event to edit or delete")
        case let .task(task):
            Button { editing = task } label: { taskRow(task) }
                .buttonStyle(.pressable(scale: 0.98))
                .taskContextMenu(task, onEdit: { editing = $0 })
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let accent = event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
        return HStack(spacing: 13) {
            Capsule().fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                HStack(spacing: 8) {
                    Text(event.isAllDay ? "All day" : "\(Self.time(event.start))–\(Self.time(event.end))")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                    if let location = event.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Color.Offload.muted)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Offload.muted.opacity(0.6))
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(task.priority == "high" ? Color.Offload.red : Color.Offload.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                HStack(spacing: 8) {
                    if let due = DueDate.parse(task.dueDate), !task.dueIsAllDay {
                        Text(Self.time(due))
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    } else if task.dueIsAllDay {
                        Text("Anytime")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
                    if let category = task.category {
                        Text(category)
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(Color.Offload.indigo)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Offload.muted.opacity(0.6))
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard(cornerRadius: 16)
    }

    static func time(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        return df.string(from: date)
    }
}

#Preview {
    CalendarView().environment(CaptureCoordinator.shared)
}
