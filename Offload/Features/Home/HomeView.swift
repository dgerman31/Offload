import SwiftUI

/// Home — your captured tasks, live (spec §5.4). Organization already happened at capture
/// time, so this just reflects the sorted world. Empty state is an invitation to capture.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()
    @State private var editing: TaskItem?

    var body: some View {
        NavigationStack {
            Group {
                if store.openTasks.isEmpty {
                    ScrollView {
                        EmptyCaptureInvitation { capture.beginCapture() }
                            .padding(.top, 60)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    List {
                        ForEach(HomeGrouping.sections(from: store.openTasks, now: Date())) { section in
                            Section(section.title) {
                                ForEach(section.tasks) { task in
                                    TaskRowView(task: task, onEdit: { editing = task }) {
                                        Task { await store.toggleComplete(task) }
                                    }
                                    .listRowBackground(Color.Offload.background)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button {
                                            Task { await store.toggleComplete(task) }
                                        } label: {
                                            Label("Done", systemImage: "checkmark")
                                        }
                                        .tint(Color.Offload.green)
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button(role: .destructive) {
                                            Task { await store.delete(task) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color.Offload.background)
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        capture.beginCapture()
                    } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Quick Capture")
                }
            }
            .task { await store.observe() }
            .sheet(item: $editing) { task in
                NavigationStack { TaskEditView(task: task) }
            }
            .overlay(alignment: .bottom) {
                if let undo = store.undo {
                    UndoBanner(message: undo.message) {
                        Task { await store.performUndo() }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: undo.id) {
                        try? await Task.sleep(for: .seconds(4))
                        store.clearUndo()
                    }
                }
            }
            .animation(.snappy, value: store.undo?.id)
        }
    }
}

/// Transient "undo" banner shown after a completion/deletion (spec §5.7).
struct UndoBanner: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.Offload.body)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.teal)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(hex: 0x1F2937), in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

/// Reusable empty-state used across tabs — an invitation, not decoration (spec §5.6).
struct EmptyCaptureInvitation: View {
    var onCapture: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.Offload.indigo)
            Text("Nothing to organize yet")
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            Text("Press the Action Button — or tap below — and just say what's on your mind. Offload sorts it out.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .multilineTextAlignment(.center)
            Button(action: onCapture) {
                Label("Capture a thought", systemImage: "mic.fill")
                    .font(.Offload.taskTitle)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 360)
    }
}

#Preview {
    HomeView().environment(CaptureCoordinator.shared)
}
