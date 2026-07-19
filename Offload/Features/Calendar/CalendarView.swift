import SwiftUI

/// The Calendar tab: a month grid you can tap into, with the selected day's real timeline
/// below — calendar events and due tasks merged in the order they'll actually happen.
/// Swipe left/right on the grid to change months.
struct CalendarView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = CalendarStore()
    @State private var editing: TaskItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    monthHeader
                    weekdayHeader
                    monthGrid
                    Divider().padding(.horizontal)
                    dayDetail
                }
                .padding(.vertical, 8)
            }
            .background(Color.Offload.background)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") { store.goToToday() }
                        .font(.Offload.taskTitle)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { capture.beginCapture() } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Quick Capture")
                }
            }
            .task { await store.observeTasks() }
            .task { await store.loadEvents() }
            .sheet(item: $editing) { task in
                NavigationStack { TaskEditView(task: task) }
            }
        }
    }

    // MARK: Month header

    private var monthHeader: some View {
        HStack {
            Button { store.moveMonth(by: -1) } label: {
                Image(systemName: "chevron.left").font(.headline)
            }
            .accessibilityLabel("Previous month")

            Spacer()
            Text(store.monthTitle)
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            Spacer()

            Button { store.moveMonth(by: 1) } label: {
                Image(systemName: "chevron.right").font(.headline)
            }
            .accessibilityLabel("Next month")
        }
        .foregroundStyle(Color.Offload.indigo)
        .padding(.horizontal)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(Color.Offload.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    // MARK: Grid

    private var monthGrid: some View {
        let density = store.densityByDay
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(store.gridDays, id: \.timeIntervalSince1970) { day in
                dayCell(day, density: density[Calendar.current.startOfDay(for: day)] ?? DayDensity())
            }
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width < -40 { store.moveMonth(by: 1) }
                    else if value.translation.width > 40 { store.moveMonth(by: -1) }
                }
        )
    }

    private func dayCell(_ day: Date, density: DayDensity) -> some View {
        let selected = store.isSelected(day)
        let today = store.isToday(day)
        let inMonth = store.isInVisibleMonth(day)

        return Button {
            store.select(day)
        } label: {
            VStack(spacing: 4) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(.callout, design: .rounded))
                    .fontWeight(today || selected ? .bold : .regular)
                    .foregroundStyle(dayNumberColor(selected: selected, today: today, inMonth: inMonth))
                    .frame(width: 32, height: 32)
                    .background {
                        if selected {
                            Circle().fill(Color.Offload.indigo)
                        } else if today {
                            Circle().stroke(Color.Offload.indigo, lineWidth: 1.5)
                        }
                    }

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
                .opacity(inMonth ? 1 : 0.35)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day, density: density, selected: selected, today: today))
    }

    private func dayNumberColor(selected: Bool, today: Bool, inMonth: Bool) -> Color {
        if selected { return .white }
        if today { return Color.Offload.indigo }
        return inMonth ? Color.Offload.text : Color.Offload.muted.opacity(0.5)
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedDayTitle)
                    .font(.Offload.section)
                    .foregroundStyle(Color.Offload.text)
                Spacer()
                if store.loadingEvents { ProgressView() }
            }

            if !store.calendarAccess {
                Label("Turn on calendar access to see your events here.", systemImage: "calendar.badge.exclamationmark")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
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
                .padding()
                .background(Color.Offload.surface, in: .rect(cornerRadius: 14))
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        timelineRow(item)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
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
            eventRow(event)
        case let .task(task):
            Button { editing = task } label: { taskRow(task) }
                .buttonStyle(.plain)
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let accent = event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
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
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: .rect(cornerRadius: 12))
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle")
                .foregroundStyle(task.priority == "high" ? Color.Offload.red : Color.Offload.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                HStack(spacing: 8) {
                    if let due = DueDate.parse(task.dueDate) {
                        Text(Self.time(due))
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
                    if let category = task.category {
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(Color.Offload.indigo)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.Offload.muted)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Offload.divider, lineWidth: 1))
    }

    static func time(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        return df.string(from: date)
    }
}

#Preview {
    CalendarView().environment(CaptureCoordinator.shared)
}
