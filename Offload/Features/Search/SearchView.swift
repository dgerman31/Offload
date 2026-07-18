import SwiftUI

/// Search — full-text + vector search with filters (spec §5.4, feature 14).
/// Placeholder shell with a search field until the data + embedding layers land.
struct SearchView: View {
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Search everything",
                systemImage: "magnifyingglass",
                description: Text("Find tasks by words or meaning — “all kitchen tasks I haven't started” — once you've captured a few.")
            )
            .background(Color.Offload.background)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Tasks, projects, ideas…")
        }
    }
}

#Preview { SearchView() }
