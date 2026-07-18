import SwiftUI

/// Search — full-text over tasks with category/priority filters (spec §5.4).
struct SearchView: View {
    @State private var store = SearchStore()

    private let categories = ["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"]
    private let priorities = ["high", "medium", "low"]

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider().overlay(Color.Offload.divider)
                resultsList
            }
            .background(Color.Offload.background)
            .navigationTitle("Search")
            .searchable(text: $store.query, prompt: "Tasks, projects, ideas…")
            .task { await store.observe() }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Any category") { store.category = nil }
                    ForEach(categories, id: \.self) { c in
                        Button(c) { store.category = c }
                    }
                } label: {
                    filterChip(store.category ?? "Category", active: store.category != nil)
                }
                Menu {
                    Button("Any priority") { store.priority = nil }
                    ForEach(priorities, id: \.self) { p in
                        Button(p.capitalized) { store.priority = p }
                    }
                } label: {
                    filterChip(store.priority?.capitalized ?? "Priority", active: store.priority != nil)
                }
                if store.category != nil || store.priority != nil {
                    Button("Clear") { store.category = nil; store.priority = nil }
                        .font(.caption)
                        .foregroundStyle(Color.Offload.indigo)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.caption).fontWeight(.medium)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background((active ? Color.Offload.indigo : Color.Offload.muted).opacity(0.12), in: .capsule)
        .foregroundStyle(active ? Color.Offload.indigo : Color.Offload.text)
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = store.results
        if results.isEmpty {
            ContentUnavailableView(
                store.all.isEmpty ? "Nothing to search yet" : "No matches",
                systemImage: "magnifyingglass",
                description: Text(store.all.isEmpty
                                  ? "Capture a few thoughts and they'll be searchable here."
                                  : "Try a different word or clear your filters.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List(results) { task in
                TaskRowView(task: task) {
                    Task { await store.toggleComplete(task) }
                }
                .listRowBackground(Color.Offload.background)
            }
            .listStyle(.plain)
        }
    }
}

#Preview { SearchView() }
