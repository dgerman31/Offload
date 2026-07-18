import SwiftUI

/// Projects — clustered captures with progress + status (spec §5.4).
/// Placeholder until project clustering (Phase 1, feature 8) lands.
struct ProjectsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No projects yet",
                systemImage: "folder",
                description: Text("When related captures pile up, Offload groups them into a project with a suggested order and rough effort.")
            )
            .background(Color.Offload.background)
            .navigationTitle("Projects")
        }
    }
}

#Preview { ProjectsView() }
