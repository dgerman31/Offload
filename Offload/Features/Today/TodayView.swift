import SwiftUI

/// Today — time-boxed sections + progress (spec §5.4), from live data.
struct TodayView: View {
    @State private var store = TodayStore()
    @State private var editing: TaskItem?

    private var isEmpty: Bool {
        store.plan.groups.isEmpty && store.plan.completedToday == 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    ContentUnavailableView(
                        "Your day, sorted",
                        systemImage: "sun.max",
                        description: Text("Tasks land here grouped by Morning, Afternoon, and Evening, with a suggestion sized to your free time.")
                    )
                } else {
                    List {
                        Section {
                            progressHeader
                        }
                        .listRowBackground(Color.Offload.background)

                        if let best = NextBest.pick(from: store.plan.groups.flatMap(\.tasks)) {
                            Section("Next best") {
                                nextBestCard(best)
                            }
                            .listRowBackground(Color.Offload.background)
                        }

                        ForEach(store.plan.groups) { group in
                            Section(group.slot.rawValue) {
                                ForEach(group.tasks) { task in
                                    TaskRowView(task: task, onEdit: { editing = task }) {
                                        Task { await store.toggleComplete(task) }
                                    }
                                    .listRowBackground(Color.Offload.background)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color.Offload.background)
            .navigationTitle("Today")
            .task { await store.observe() }
            .sheet(item: $editing) { task in
                NavigationStack { TaskEditView(task: task) }
            }
        }
    }

    private func nextBestCard(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(Color.Offload.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                if let effort = task.effortMinutes {
                    Text("~\(effort) min")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
            }
            Spacer()
            Button {
                Task { await store.toggleComplete(task) }
            } label: {
                Text("Do it").font(.Offload.taskTitle)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today's progress")
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Spacer()
                Text("\(store.plan.completedToday) done · \(store.plan.openToday) left")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            ProgressView(value: store.plan.progress)
                .tint(Color.Offload.teal)
        }
        .padding(.vertical, 4)
    }
}

#Preview { TodayView() }
