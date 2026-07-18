import SwiftUI

/// Home — your captured tasks, live (spec §5.4). Organization already happened at capture
/// time, so this just reflects the sorted world. Empty state is an invitation to capture.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @State private var store = TaskStore()

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
                                    TaskRowView(task: task) {
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
        }
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
