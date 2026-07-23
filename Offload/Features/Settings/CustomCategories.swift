import Foundation
import SwiftUI

/// User-defined categories on top of the built-in eight.
///
/// The fixed set (Work, Personal, Health, Finance, Projects, Ideas, Habits, Other) covers most
/// lives but not every one — someone running a side business, studying, or managing a chronic
/// condition needs their own bucket, and forcing that into "Other" throws away exactly the
/// structure the app is supposed to provide.
///
/// Stored in preferences rather than the database: they're configuration, not content, and
/// keeping them out of the schema means no migration and no orphaned rows when one is removed.
enum CustomCategories {
    static let storageKey = "offload.categories.custom"
    /// Keeping the total sane also keeps the extraction prompt short.
    static let maxCustom = 6

    /// The immutable defaults, which can never be removed — tasks always have somewhere to live.
    static let builtIn = ["Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Study", "Other"]

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        guard let json = defaults.string(forKey: storageKey),
              let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    static func save(_ names: [String], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(names),
              let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: storageKey)
    }

    /// Normalise a proposed name and reject anything that clashes or is nonsense. Returns nil
    /// when it shouldn't be added.
    static func normalized(_ raw: String, existing: [String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 20 else { return nil }

        // Title-case so the list looks deliberate regardless of how it was typed.
        let name = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        let all = builtIn + existing
        guard !all.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        guard existing.count < maxCustom else { return nil }
        return name
    }

    /// Everything a picker should offer.
    static func all(_ defaults: UserDefaults = .standard) -> [String] {
        builtIn + load(defaults)
    }
}

/// Settings screen for managing the extra categories.
struct CategoriesView: View {
    @State private var custom: [String] = CustomCategories.load()
    @State private var newName = ""
    @State private var rejected = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        List {
            Section {
                ForEach(CustomCategories.builtIn, id: \.self) { name in
                    Label {
                        Text(name)
                    } icon: {
                        Circle()
                            .fill(Color.Offload.accent(for: name))
                            .frame(width: 10, height: 10)
                    }
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("These can't be removed, so every task always has somewhere to live.")
            }

            Section {
                ForEach(custom, id: \.self) { name in
                    Label {
                        Text(name)
                    } icon: {
                        Circle()
                            .fill(Color.Offload.accent(for: name))
                            .frame(width: 10, height: 10)
                    }
                }
                .onDelete { offsets in
                    custom.remove(atOffsets: offsets)
                    CustomCategories.save(custom)
                    Haptics.light()
                }

                if custom.count < CustomCategories.maxCustom {
                    HStack {
                        TextField("Add a category", text: $newName)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        if !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Add", action: add)
                                .font(.caption).fontWeight(.semibold)
                        }
                    }
                }
            } header: {
                Text("Your categories")
            } footer: {
                if rejected {
                    Text("That name is already taken, too short, or you've reached the limit.")
                        .foregroundStyle(Color.Offload.amber)
                } else {
                    Text("Up to \(CustomCategories.maxCustom). Removing one leaves existing tasks untouched — they simply keep the name.")
                }
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard let name = CustomCategories.normalized(newName, existing: custom) else {
            withAnimation(Motion.standard) { rejected = true }
            Haptics.warning()
            return
        }
        withAnimation(Motion.standard) {
            custom.append(name)
            rejected = false
        }
        CustomCategories.save(custom)
        newName = ""
        Haptics.success()
    }
}
