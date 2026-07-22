import SwiftUI

/// Drag to set the order you'll actually tackle a day's flexible work in — reached directly from
/// the Day tab, for whichever day is showing. Only non-anchored tasks are here at all: pinned
/// times and real events are commitments, not a sequence choice, so they never appear.
///
/// On "Done," the new order becomes `DayPlanner`'s `preferredOrder` for a fresh plan of that day,
/// and only the tasks whose time actually changed get written back (`TaskStore.applyReorder`) —
/// dragging "Gym" above "Email boss" swaps their times to match the new sequence.
struct DayReorderSheet: View {
    let day: Date
    let events: [CalendarEvent]
    var store: TaskStore
    var onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var order: [TaskItem]
    @State private var applying = false

    init(day: Date, flexibleTasks: [TaskItem], events: [CalendarEvent], store: TaskStore, onApplied: @escaping () -> Void) {
        self.day = day
        self.events = events
        self.store = store
        self.onApplied = onApplied
        _order = State(initialValue: flexibleTasks)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { task in
                        row(task)
                            .listRowBackground(Color.Offload.background)
                    }
                    .onMove { source, destination in
                        order = ProjectDetailStore.moved(order, fromOffsets: source, toOffset: destination)
                        Haptics.light()
                    }
                } footer: {
                    Text("Drag to set the order you'd actually do these in — times shift to match.")
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .background(Color.Offload.background)
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await apply() }
                    } label: {
                        if applying { ProgressView() } else { Text("Done").fontWeight(.semibold) }
                    }
                    .disabled(applying)
                }
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.Offload.accent(for: task.category))
                .frame(width: 8, height: 8)
            Text(task.title)
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.text)
            Spacer(minLength: 8)
            if let due = DueDate.parse(task.dueDate), !task.dueIsAllDay {
                Text(CalendarView.time(due))
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            } else {
                Text("Anytime")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private func apply() async {
        applying = true
        await store.applyReorder(order.map(\.id), on: day, events: events)
        applying = false
        onApplied()
        dismiss()
    }
}
