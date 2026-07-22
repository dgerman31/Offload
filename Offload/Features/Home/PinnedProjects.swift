import SwiftUI

/// The user's pinned Home shortcuts: an ordered list of project IDs, persisted as a simple CSV
/// in `UserDefaults` (project IDs are UUIDs, so commas are safe). Kept tiny and string-based so
/// `@AppStorage` can bind to it directly and both Home and the edit sheet stay in sync live.
enum PinnedProjects {
    static let key = "home.pinnedProjectIDs"

    static func parse(_ csv: String) -> [String] {
        csv.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    static func format(_ ids: [String]) -> String { ids.joined(separator: ",") }

    /// Toggle a pin inside a CSV string, returning the new CSV. New pins append to the end so the
    /// bento order reflects the order the user pinned things.
    static func toggled(_ id: String, in csv: String) -> String {
        var ids = parse(csv)
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        return format(ids)
    }

    /// Resolve pinned IDs to live project summaries, preserving pin order and dropping any that
    /// no longer exist. Flattens the tree so a pinned subfolder resolves too.
    static func resolve(_ ids: [String], from roots: [ProjectStore.Summary]) -> [ProjectStore.Summary] {
        let all = flatten(roots)
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    static func flatten(_ roots: [ProjectStore.Summary]) -> [ProjectStore.Summary] {
        roots.flatMap { [$0] + flatten($0.children) }
    }

    // The bento's accent + glyph rotation, matching the redesign's tile palette. Colour is by
    // slot (stable for a given pin order), not by project, so the row always reads as a set.
    private static let accents: [Color] = [
        Color(hex: 0x7A5AE0), Color(hex: 0x16A9A3), Color(hex: 0x4C6FE7),
        Color(hex: 0xE8547C), Color(hex: 0xD79A2B), Color(hex: 0x2E8BC9)
    ]
    private static let glyphs = [
        "book.fill", "checklist", "square.stack.3d.up.fill",
        "target", "list.bullet.rectangle.fill", "folder.fill"
    ]
    static func accent(_ slot: Int) -> Color { accents[((slot % accents.count) + accents.count) % accents.count] }
    static func glyph(_ slot: Int) -> String { glyphs[((slot % glyphs.count) + glyphs.count) % glyphs.count] }
}

/// The "PINNED" bento on Home: a label row with an Edit action over a 3-wide grid of project
/// shortcut tiles. Tiles push into the project; Edit opens the picker. When nothing is pinned it
/// invites the user to add some rather than showing an empty gap.
struct PinnedBento: View {
    let summaries: [ProjectStore.Summary]
    var onEdit: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PINNED")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(Color.Offload.muted)
                Spacer()
                Button("Edit", action: onEdit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Offload.indigo)
                    .buttonStyle(.pressable)
            }

            if summaries.isEmpty {
                Button(action: onEdit) {
                    HStack(spacing: 8) {
                        Image(systemName: "pin.fill").font(.system(size: 13, weight: .semibold))
                        Text("Pin a project or list for one-tap access")
                            .font(.Offload.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.Offload.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(Color.Offload.divider)
                    )
                }
                .buttonStyle(.pressable(scale: 0.99))
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { slot, summary in
                        NavigationLink {
                            ProjectDetailView(project: summary.project)
                        } label: {
                            tile(summary, slot: slot)
                        }
                        .buttonStyle(.pressable(scale: 0.97))
                    }
                }
            }
        }
    }

    private func tile(_ summary: ProjectStore.Summary, slot: Int) -> some View {
        let accent = PinnedProjects.accent(slot)
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: PinnedProjects.glyph(slot))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.2), in: .rect(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.project.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.Offload.text)
                    .lineLimit(1)
                Text("\(summary.total) task\(summary.total == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(accent.opacity(0.15), in: .rect(cornerRadius: 18, style: .continuous))
    }
}

/// The pin picker: every project (and subfolder) with a toggle. Writes straight to the shared
/// `@AppStorage` CSV, so Home updates the instant a pin changes.
struct PinEditSheet: View {
    let summaries: [ProjectStore.Summary]
    @AppStorage(PinnedProjects.key) private var pinnedCSV = ""
    @Environment(\.dismiss) private var dismiss

    private var all: [ProjectStore.Summary] { PinnedProjects.flatten(summaries) }

    var body: some View {
        NavigationStack {
            Group {
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "folder")
                    } description: {
                        Text("Create a project first, then pin it here for one-tap access on Home.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(all) { summary in
                                row(summary)
                            }
                        } footer: {
                            Text("Pinned projects appear as tiles at the top of Home.")
                        }
                    }
                }
            }
            .navigationTitle("Edit pins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ summary: ProjectStore.Summary) -> some View {
        let pinned = PinnedProjects.parse(pinnedCSV).contains(summary.id)
        return Button {
            pinnedCSV = PinnedProjects.toggled(summary.id, in: pinnedCSV)
            Haptics.light()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: summary.hasChildren ? "folder.fill.badge.plus" : "folder.fill")
                    .foregroundStyle(Color.Offload.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.project.title)
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    Text("\(summary.total) task\(summary.total == 1 ? "" : "s")")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Color.Offload.indigo : Color.Offload.muted.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
