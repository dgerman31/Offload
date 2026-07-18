import SwiftUI

/// Today — time-boxed sections + progress (spec §5.4), from live data.
struct TodayView: View {
    @State private var store = TodayStore()

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

                        ForEach(store.plan.groups) { group in
                            Section(group.slot.rawValue) {
                                ForEach(group.tasks) { task in
                                    TaskRowView(task: task) {
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
        }
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
