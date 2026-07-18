import SwiftUI

/// A single project's tasks, grouped To-do / Done, with completion (spec §5.4).
struct ProjectDetailView: View {
    let project: Project
    @State private var store: ProjectDetailStore
    @State private var editing: TaskItem?

    init(project: Project) {
        self.project = project
        _store = State(initialValue: ProjectDetailStore(projectId: project.id))
    }

    var body: some View {
        List {
            if store.todo.isEmpty && store.done.isEmpty {
                ContentUnavailableView(
                    "No tasks in this project yet",
                    systemImage: "tray",
                    description: Text("Capture related thoughts and they'll gather here.")
                )
            }
            if !store.todo.isEmpty {
                Section("Suggested order") {
                    ForEach(Array(store.todo.enumerated()), id: \.element.id) { index, task in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                                .frame(width: 22, height: 22)
                                .background(Color.Offload.indigo.opacity(0.12), in: .circle)
                                .foregroundStyle(Color.Offload.indigo)
                                .padding(.top, 4)
                            TaskRowView(task: task, onEdit: { editing = task }) { Task { await store.toggleComplete(task) } }
                        }
                        .listRowBackground(Color.Offload.background)
                    }
                }
            }
            if !store.done.isEmpty {
                Section("Done") {
                    ForEach(store.done) { task in
                        TaskRowView(task: task, onEdit: { editing = task }) { Task { await store.toggleComplete(task) } }
                            .listRowBackground(Color.Offload.background)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color.Offload.background)
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .sheet(item: $editing) { task in
            NavigationStack { TaskEditView(task: task) }
        }
    }
}
