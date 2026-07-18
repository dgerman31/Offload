import SwiftUI

/// Projects — clustered captures with live progress + status (spec §5.4).
struct ProjectsView: View {
    @State private var store = ProjectStore()

    var body: some View {
        NavigationStack {
            Group {
                if store.summaries.isEmpty {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "folder",
                        description: Text("When related captures pile up, Offload groups them into a project with a suggested order and rough effort.")
                    )
                } else {
                    List(store.summaries) { summary in
                        ProjectRowView(summary: summary)
                            .listRowBackground(Color.Offload.background)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.Offload.background)
            .navigationTitle("Projects")
            .task { await store.observe() }
        }
    }
}

private struct ProjectRowView: View {
    let summary: ProjectStore.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.project.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Spacer()
                Text("\(summary.completed)/\(summary.total)")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            ProgressView(value: summary.progress)
                .tint(summary.progress >= 1 ? Color.Offload.green : Color.Offload.indigo)
            statusLabel
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusLabel: some View {
        let (text, color): (String, Color) = {
            if summary.total > 0 && summary.progress >= 1 { return ("Completed", Color.Offload.green) }
            switch summary.project.status {
            case "on_track": return ("On Track", Color.Offload.teal)
            case "stalled":  return ("Stalled", Color.Offload.amber)
            default:         return ("Planning", Color.Offload.muted)
            }
        }()
        Text(text)
            .font(.caption).fontWeight(.medium)
            .foregroundStyle(color)
    }
}

#Preview { ProjectsView() }
