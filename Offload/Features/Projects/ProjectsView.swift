import SwiftUI

/// Projects — clustered captures with live progress + status (spec §5.4), now a real folder
/// tree: any project can hold subfolders, and a parent's progress rolls up everything beneath
/// it. Create projects by hand here, or let a capture suggest one.
struct ProjectsView: View {
    @State private var store = ProjectStore()
    @State private var newProjectParent: NewProjectTarget?
    @State private var expanded: Set<String> = []
    @State private var appeared = false

    /// Identifies which "new project" sheet is open — top level, or inside a parent.
    struct NewProjectTarget: Identifiable {
        let parent: Project?
        var id: String { parent?.id ?? "root" }
    }

    /// One rendered line of the tree. The hierarchy is flattened into rows rather than drawn
    /// with a recursive `@ViewBuilder` — a view function that returns `some View` and calls
    /// itself would form an infinitely self-referential opaque type.
    struct FlatRow: Identifiable {
        let summary: ProjectStore.Summary
        let depth: Int
        var id: String { summary.id }
    }

    /// Depth-first walk that descends only into expanded folders.
    private var visibleRows: [FlatRow] {
        var rows: [FlatRow] = []
        func walk(_ items: [ProjectStore.Summary], depth: Int) {
            for item in items {
                rows.append(FlatRow(summary: item, depth: depth))
                if expanded.contains(item.id) {
                    walk(item.children, depth: depth + 1)
                }
            }
        }
        walk(store.summaries, depth: 0)
        return rows
    }

    var body: some View {
        // No NavigationStack of its own: Projects is now pushed from Home (it left the tab bar),
        // so it lives inside Home's navigation stack and its rows push detail there.
        Group {
            if store.summaries.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "folder")
                    } description: {
                        Text("Group related work into projects and subfolders — or let a capture suggest one.")
                    } actions: {
                        Button("New project") { newProjectParent = .init(parent: nil) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                                projectRow(row)
                                    .padding(.leading, CGFloat(row.depth) * 18)
                                    .appearIn(min(index, 8), when: appeared)
                                    .scrollAppear(scale: 0.97, lift: 10)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .padding(.bottom, 40)
                        .animation(Motion.standard, value: expanded)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.Offload.background)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newProjectParent = .init(parent: nil) } label: {
                        Image(systemName: "folder.badge.plus").font(.body)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("New project")
                }
            }
            .task { await store.observe() }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .sheet(item: $newProjectParent) { target in
                NewProjectSheet(parent: target.parent) { title in
                    Task { await store.create(title: title, parentId: target.parent?.id) }
                }
            }
    }

    /// A single row of the flattened tree: disclosure control, then the project itself.
    private func projectRow(_ row: FlatRow) -> some View {
        let summary = row.summary
        let isExpanded = expanded.contains(summary.id)
        return HStack(spacing: 8) {
            if summary.hasChildren {
                Button {
                    withAnimation(Motion.standard) { toggleExpanded(summary.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.Offload.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.pressable(scale: 0.85))
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: 20, height: 20)
            }

            NavigationLink {
                ProjectDetailView(project: summary.project)
            } label: {
                ProjectRowView(summary: summary)
            }
            .buttonStyle(.pressable(scale: 0.99))
        }
        .padding(12)
        .offloadCard(cornerRadius: 16)
        .contextMenu {
            Button {
                newProjectParent = .init(parent: summary.project)
            } label: {
                Label("Add subfolder", systemImage: "folder.badge.plus")
            }
            if summary.project.parentProjectId != nil {
                Button {
                    Task { await store.move(summary.project, under: nil) }
                } label: {
                    Label("Move to top level", systemImage: "arrow.up.left")
                }
            }
            Button(role: .destructive) {
                Task { await store.delete(summary.project) }
            } label: {
                Label("Delete project", systemImage: "trash")
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

// MARK: - Row

private struct ProjectRowView: View {
    let summary: ProjectStore.Summary

    var body: some View {
        HStack(spacing: 14) {
            // Per-project progress ring — rolled up across subfolders.
            ZStack {
                Circle().stroke(Color.Offload.divider, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: summary.progress)
                    .stroke(summary.progress >= 1 ? Color.Offload.green : Color.Offload.indigo,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.settle, value: summary.progress)
                Image(systemName: summary.progress >= 1 && summary.total > 0
                      ? "checkmark"
                      : (summary.hasChildren ? "folder.fill.badge.plus" : "folder.fill"))
                    .font(.caption)
                    .foregroundStyle(summary.progress >= 1 && summary.total > 0 ? Color.Offload.green : Color.Offload.indigo)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.project.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            statusPill
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if summary.total > 0 { parts.append("\(summary.completed) of \(summary.total) done") }
        if summary.hasChildren {
            parts.append("\(summary.children.count) subfolder\(summary.children.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
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
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.14), in: .capsule)
            .foregroundStyle(color)
    }
}

// MARK: - New project sheet

struct NewProjectSheet: View {
    let parent: Project?
    var onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    if let parent {
                        Text("This will be a subfolder inside “\(parent.title)”.")
                    } else {
                        Text("A place to gather related tasks. You can add subfolders inside it later.")
                    }
                }
            }
            .navigationTitle(parent == nil ? "New project" : "New subfolder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220)])
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

#Preview { ProjectsView() }
