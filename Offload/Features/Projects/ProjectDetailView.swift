import SwiftUI

/// A single project's tasks, grouped To-do / Done, with completion (spec §5.4).
struct ProjectDetailView: View {
    let project: Project
    @State private var store: ProjectDetailStore

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
                Section("To do") {
                    ForEach(store.todo) { task in
                        TaskRowView(task: task) { Task { await store.toggleComplete(task) } }
                            .listRowBackground(Color.Offload.background)
                    }
                }
            }
            if !store.done.isEmpty {
                Section("Done") {
                    ForEach(store.done) { task in
                        TaskRowView(task: task) { Task { await store.toggleComplete(task) } }
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
    }
}
