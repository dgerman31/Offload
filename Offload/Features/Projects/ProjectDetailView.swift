import SwiftUI

/// A single project: its subfolders, then its tasks grouped To-do / Done (spec §5.4).
struct ProjectDetailView: View {
    let project: Project
    @State private var store: ProjectDetailStore
    @State private var editing: TaskItem?
    @State private var addingSubfolder = false

    init(project: Project) {
        self.project = project
        _store = State(initialValue: ProjectDetailStore(projectId: project.id))
    }

    private var isEmpty: Bool {
        store.todo.isEmpty && store.done.isEmpty && store.subfolders.isEmpty
    }

    var body: some View {
        List {
            if isEmpty {
                ContentUnavailableView {
                    Label("Nothing here yet", systemImage: "tray")
                } description: {
                    Text("Capture related thoughts and they'll gather here — or add a subfolder to break this project down.")
                } actions: {
                    Button("Add subfolder") { addingSubfolder = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.Offload.background)
            }

            if !store.subfolders.isEmpty {
                Section("Subfolders") {
                    ForEach(store.subfolders) { child in
                        NavigationLink {
                            ProjectDetailView(project: child.project)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.Offload.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.project.title)
                                        .font(.Offload.taskTitle)
                                        .foregroundStyle(Color.Offload.text)
                                        .lineLimit(1)
                                    Text(child.total == 0 ? "Empty" : "\(child.completed) of \(child.total) done")
                                        .font(.Offload.data)
                                        .foregroundStyle(Color.Offload.muted)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .listRowBackground(Color.Offload.background)
                    }
                }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingSubfolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("Add subfolder")
            }
        }
        .task { await store.observe() }
        .sheet(item: $editing) { task in
            NavigationStack { TaskEditView(task: task) }
        }
        .sheet(isPresented: $addingSubfolder) {
            NewProjectSheet(parent: project) { title in
                Task { await store.addSubfolder(named: title) }
            }
        }
    }
}
