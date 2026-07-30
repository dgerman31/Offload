import SwiftUI
import GRDB

/// The grocery list. Add fast, tick in the aisle, empty when you're home.
@MainActor
@Observable
final class GroceryStore {
    private(set) var items: [GroceryItem] = []

    private let db: AppDatabase
    private var started = false

    init(db: AppDatabase = .shared) { self.db = db }

    var boughtCount: Int { items.filter(\.bought).count }
    var remaining: Int { items.count - boughtCount }

    func observe() async {
        guard !started else { return }
        started = true
        let observation = ValueObservation.tracking { database in
            try GroceryItem.order(Column("sort_order")).fetchAll(database)
        }
        do {
            for try await rows in observation.values(in: db.dbQueue) {
                items = rows
            }
        } catch {
            Log.database.error("Grocery observation stopped: \(CaptureService.errorKind(error), privacy: .public)")
        }
    }

    /// Add one line. Splits on commas and newlines, so pasting or dictating "milk, eggs, bread"
    /// gives three items rather than one long one — the fastest way to fill a list is usually to
    /// say the whole lot at once.
    func add(_ text: String) async {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        var order = (items.map(\.sortOrder).max() ?? 0)
        let rows = parts.map { title -> GroceryItem in
            order += 1
            return GroceryItem(title: title, sortOrder: order)
        }
        do {
            try await db.dbQueue.write { database in
                for row in rows { try row.insert(database) }
            }
            Haptics.light()
        } catch {
            Log.database.error("Adding \(rows.count, privacy: .public) grocery item(s) failed: \(CaptureService.errorKind(error), privacy: .public)")
        }
    }

    func toggle(_ item: GroceryItem) async {
        var updated = item
        updated.bought.toggle()
        let toSave = updated          // immutable copy for the @Sendable write closure
        try? await db.dbQueue.write { try toSave.update($0) }
        Haptics.light()
    }

    func delete(_ items: [GroceryItem]) async {
        let ids = items.map(\.id)
        try? await db.dbQueue.write { database in
            _ = try GroceryItem.filter(keys: ids).deleteAll(database)
        }
    }

    /// Clear the ticked ones — the "I've bought it" button. Separate from clearing everything,
    /// because a shop that got interrupted shouldn't cost you the rest of the list.
    func clearBought() async {
        try? await db.dbQueue.write { database in
            _ = try GroceryItem.filter(Column("bought") == true).deleteAll(database)
        }
        Haptics.success()
    }

    func clearAll() async {
        try? await db.dbQueue.write { database in
            _ = try GroceryItem.deleteAll(database)
        }
        Haptics.success()
    }
}

/// A plain list — no dates, no priorities, no AI. Groceries don't need any of it.
struct GroceryListView: View {
    @State private var store = GroceryStore()
    @State private var entry = ""
    @State private var confirmingClearAll = false
    @FocusState private var entryFocused: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Milk, eggs, bread…", text: $entry, axis: .vertical)
                        .focused($entryFocused)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                    if !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Add") { commit() }
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(Color.Offload.indigo)
                    }
                }
            } footer: {
                Text("Commas split into separate items, so you can add the whole lot at once.")
            }

            if store.items.isEmpty {
                Section {
                    Text("Nothing on the list.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                }
            } else {
                Section {
                    ForEach(store.items) { item in
                        Button {
                            Task { await store.toggle(item) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.bought ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(item.bought ? Color.Offload.green : Color.Offload.muted.opacity(0.55))
                                    .symbolEffect(.bounce, value: item.bought)
                                Text(item.title)
                                    .font(.Offload.body)
                                    .strikethrough(item.bought, color: Color.Offload.muted)
                                    .foregroundStyle(item.bought ? Color.Offload.muted : Color.Offload.text)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { store.items[$0] }
                        Task { await store.delete(doomed) }
                    }
                } header: {
                    Text(store.remaining == 0 ? "All picked up" : "\(store.remaining) to get")
                }
            }
        }
        .navigationTitle("Groceries")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await store.clearBought() }
                    } label: {
                        Label("Clear what I bought (\(store.boughtCount))", systemImage: "checkmark.circle")
                    }
                    .disabled(store.boughtCount == 0)

                    Button(role: .destructive) {
                        confirmingClearAll = true
                    } label: {
                        Label("Clear the whole list", systemImage: "trash")
                    }
                    .disabled(store.items.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Clear the whole list?", isPresented: $confirmingClearAll, titleVisibility: .visible) {
            Button("Clear \(store.items.count) items", role: .destructive) {
                Task { await store.clearAll() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes everything, bought or not.")
        }
    }

    private func commit() {
        let text = entry
        entry = ""
        Task { await store.add(text) }
        entryFocused = true      // keep the field up: lists are written in bursts
    }
}

/// The Home entry point — a count and a way in, nothing more.
struct GroceryCard: View {
    @State private var store = GroceryStore()

    var body: some View {
        NavigationLink {
            GroceryListView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.Offload.accent(for: "Personal"))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Groceries")
                        .font(.Offload.manrope(14, .bold))
                        .foregroundStyle(Color.Offload.text)
                    Text(subtitle)
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Offload.muted.opacity(0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Offload.surface, in: .rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .task { await store.observe() }
    }

    private var subtitle: String {
        if store.items.isEmpty { return "Nothing on the list" }
        if store.remaining == 0 { return "All \(store.items.count) picked up" }
        return "\(store.remaining) to get"
    }
}
