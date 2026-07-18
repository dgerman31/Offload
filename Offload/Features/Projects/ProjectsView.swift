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
                        NavigationLink {
                            ProjectDetailView(project: summary.project)
                        } label: {
                            ProjectRowView(summary: summary)
                        }
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
        HStack(spacing: 14) {
            // Per-project progress ring.
            ZStack {
                Circle().stroke(Color.Offload.divider, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: summary.progress)
                    .stroke(summary.progress >= 1 ? Color.Offload.green : Color.Offload.indigo,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: summary.progress >= 1 ? "checkmark" : "folder.fill")
                    .font(.caption)
                    .foregroundStyle(summary.progress >= 1 ? Color.Offload.green : Color.Offload.indigo)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.project.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text("\(summary.completed) of \(summary.total) done")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer()
            statusPill
        }
        .padding(.vertical, 6)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if summary.total > 0 && summary.progress >= 1 { return ("Done", Color.Offload.green) }
            switch summary.project.status {
            case "on_track": return ("On Track", Color.Offload.teal)
            case "stalled":  return ("Stalled", Color.Offload.amber)
            default:         return ("Planning", Color.Offload.muted)
            }
        }()
        return Text(text)
            .font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.14), in: .capsule)
            .foregroundStyle(color)
    }
}

#Preview { ProjectsView() }
