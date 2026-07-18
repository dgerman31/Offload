import SwiftUI

/// Today — time-boxed sections + progress (spec §5.4), from live data.
struct TodayView: View {
    @State private var store = TodayStore()
    @State private var editing: TaskItem?
    @State private var batchMinutes: Int?

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

                        Section("Got some time?") {
                            energyBatchPicker
                            if let minutes = batchMinutes {
                                let batch = EnergyBatch.plan(tasks: store.plan.groups.flatMap(\.tasks), minutes: minutes)
                                if batch.isEmpty {
                                    Text("Nothing fits in \(minutes) min right now.")
                                        .font(.Offload.body)
                                        .foregroundStyle(Color.Offload.muted)
                                } else {
                                    ForEach(batch) { task in
                                        TaskRowView(task: task, onEdit: { editing = task }) {
                                            Task { await store.toggleComplete(task) }
                                        }
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.Offload.background)

                        ForEach(store.plan.groups) { group in
                            Section {
                                ForEach(group.tasks) { task in
                                    TaskRowView(task: task, onEdit: { editing = task }) {
                                        Task { await store.toggleComplete(task) }
                                    }
                                    .listRowBackground(Color.Offload.background)
                                }
                            } header: {
                                Label(group.slot.rawValue, systemImage: slotIcon(group.slot))
                                    .font(.caption).fontWeight(.semibold)
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

    private var energyBatchPicker: some View {
        HStack(spacing: 8) {
            Text("I have")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    batchMinutes = (batchMinutes == minutes) ? nil : minutes
                } label: {
                    Text("\(minutes)m")
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background((batchMinutes == minutes ? Color.Offload.indigo : Color.Offload.muted).opacity(0.15), in: .capsule)
                        .foregroundStyle(batchMinutes == minutes ? Color.Offload.indigo : Color.Offload.text)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
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

    private func slotIcon(_ slot: TodayStore.Slot) -> String {
        switch slot {
        case .morning:   return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening:   return "moon.fill"
        case .anytime:   return "infinity"
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 16) {
            // Progress ring — clearer at a glance than a bar.
            ZStack {
                Circle()
                    .stroke(Color.Offload.divider, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: store.plan.progress)
                    .stroke(Color.Offload.teal, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(store.plan.progress * 100))%")
                    .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                    .foregroundStyle(Color.Offload.text)
            }
            .frame(width: 56, height: 56)
            .animation(.snappy, value: store.plan.progress)

            VStack(alignment: .leading, spacing: 2) {
                Text("Today's progress")
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text("\(store.plan.completedToday) done · \(store.plan.openToday) left")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview { TodayView() }
