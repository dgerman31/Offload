import SwiftUI

/// A project, as somewhere you actually run it from.
///
/// ### What was wrong with the old one
///
/// It was a to-do list with a Done pile under it. That shape is why a capture full of *ideas* came
/// back looking like a chore list — there was nowhere else for anything to go — and it's why a
/// project could sit open for a month without the screen ever saying so. A folder tells you what's
/// inside. It doesn't tell you where the thing stands, what's blocking it, what you decided, or
/// what to do next.
///
/// ### What this answers instead
///
/// - **Where does this stand?** The hill chart, with its own history, so *stuck* is visible.
/// - **What do I do next?** One nominated next action, at the top, with a way to start it.
/// - **What's in the way?** Waiting-on and open questions get their own sections rather than
///   hiding among the to-dos.
/// - **What did I decide, and why?** Decisions and notes are kept, dated, and never turn into chores.
/// - **Is it moving?** The log.
///
/// Sections come from `ProjectBoard`, which is pure and tested; this file is presentation.
struct ProjectWorkspaceView: View {
    let project: Project

    @State private var store: ProjectDetailStore
    @State private var editing: TaskItem?
    @State private var addingSubfolder = false
    @State private var addingKind: CaptureKind?
    @State private var loggingUpdate = false
    @State private var editingBrief = false
    @State private var showingLog = false
    @State private var generatedBrief: String?
    @State private var generatingBrief = false
    @State private var appeared = false
    /// Set while a Next-actions row is in the air, so the scroll view holds still under it.
    @State private var reordering = false

    init(project: Project) {
        self.project = project
        _store = State(initialValue: ProjectDetailStore(projectId: project.id))
    }

    /// The live row when the observation has produced one, falling back to what we were handed so
    /// the header renders on the first frame rather than flashing empty.
    private var live: Project { store.project ?? project }

    private var sections: [ProjectBoard.Section] { ProjectBoard.sections(store.tasks) }
    private var doneItems: [TaskItem] { ProjectBoard.done(store.tasks) }
    private var nextAction: TaskItem? { ProjectBoard.nextAction(store.tasks) }

    private var isEmpty: Bool { store.tasks.isEmpty && store.subfolders.isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header.appearIn(0, when: appeared)

                if let nextAction {
                    nextActionCard(nextAction).appearIn(1, when: appeared).scrollAppear()
                }

                if isEmpty {
                    emptyState.appearIn(2, when: appeared)
                }

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    sectionCard(section)
                        .appearIn(min(index + 2, 6), when: appeared)
                        .scrollAppear()
                }

                if !store.subfolders.isEmpty {
                    subfoldersCard.scrollAppear()
                }

                logCard.scrollAppear()

                if !doneItems.isEmpty {
                    doneCard.scrollAppear()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(reordering)
        .closesSwipeRailsOnScroll()
        .background(Color.Offload.background)
        .navigationTitle(live.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await store.observe() }
        .task { withAnimation(Motion.settle) { appeared = true } }
        .sheet(item: $editing) { task in
            NavigationStack { TaskDetailView(task: task) }
        }
        .sheet(item: $addingKind) { kind in
            QuickAddSheet(kind: kind, projectTitle: live.title) { title in
                Task { await store.add(title, kind: kind) }
            }
        }
        .sheet(isPresented: $addingSubfolder) {
            NewProjectSheet(parent: live) { title in
                Task { await store.addSubfolder(named: title) }
            }
        }
        .sheet(isPresented: $loggingUpdate) {
            ProjectUpdateSheet { note in
                Task { await store.logUpdate(note: note) }
            }
        }
        .sheet(isPresented: $editingBrief) {
            ProjectBriefSheet(text: live.descriptionText ?? "") { text in
                Task { await store.setBrief(text) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.isStalled, let days = ProjectHill.daysSinceMoved(live.hillUpdatedAt) {
                // The one thing a project view owes you that a task list never says.
                Label("Hasn't moved in \(days) days", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(Color.Offload.amber)
            }

            HillChartView(
                hill: live.hill,
                history: store.hillHistory,
                onChange: { _ in },
                onCommit: { value in Task { await store.setHill(value) } }
            )

            if let runway = ProjectBoard.runway(live, tasks: store.tasks) {
                Text(runway)
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }

            briefBlock
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    /// The project in your own words. Written by you, or drafted from its real numbers — never
    /// invented, and always editable, because a brief you can't correct is one you stop reading.
    @ViewBuilder
    private var briefBlock: some View {
        let written = live.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.4)
            if !written.isEmpty {
                Text(written)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let generatedBrief {
                Text(generatedBrief)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ProjectBrief.deterministicBrief(
                    ProjectBrief.facts(project: live, tasks: store.tasks, now: Date())
                ))
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button { editingBrief = true } label: {
                    Label(written.isEmpty ? "Write a brief" : "Edit brief", systemImage: "square.and.pencil")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.indigoText)
                }
                .buttonStyle(.pressable)

                Button {
                    generatingBrief = true
                    Task {
                        generatedBrief = await ProjectBrief.generate(project: live, tasks: store.tasks)
                        generatingBrief = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if generatingBrief { ProgressView().controlSize(.small) }
                        Label("Draft one", systemImage: "sparkles")
                            .font(.caption).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.Offload.muted.opacity(0.12), in: .capsule)
                    .foregroundStyle(Color.Offload.muted)
                }
                .buttonStyle(.pressable)
                .disabled(generatingBrief)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: The one thing

    /// The next action, given its own card because it's the answer to the only question that gets
    /// a project finished. Straight from GTD: a project without a next action is a project that
    /// stalls, and the fix is to make the nomination visible rather than implicit.
    private func nextActionCard(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Next action", systemImage: "arrow.forward.circle.fill")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(Color.Offload.indigoText)
            Text(task.title)
                .font(.Offload.manrope(19, .bold))
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    FocusTimer.shared.start(task: task)
                    FocusTimer.shared.isExpanded = true
                } label: {
                    Label("Start focus", systemImage: "timer")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.Offload.indigo, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
                Button {
                    Haptics.success()
                    Task { await store.toggleComplete(task) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.Offload.muted.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.muted)
                }
                .buttonStyle(.pressable)
                Spacer(minLength: 0)
            }
            Text("Drag a row to the top of Next actions to nominate a different one.")
                .font(.Offload.data)
                .foregroundStyle(Color.Offload.muted.opacity(0.8))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    // MARK: Sections

    private func sectionCard(_ section: ProjectBoard.Section) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(section.title, systemImage: section.kind.symbol)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(tint(for: section.kind))
                Spacer(minLength: 0)
                Text("\(section.items.count)")
                    .font(.Offload.data)
                    .monospacedDigit()
                    .foregroundStyle(Color.Offload.muted)
                Button { addingKind = section.kind } label: {
                    Image(systemName: "plus")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Color.Offload.muted)
                        .hitTarget(32)
                }
                .buttonStyle(.pressable(scale: 0.9))
                .accessibilityLabel("Add to \(section.title)")
            }

            if section.kind.sectionTitle == CaptureKind.task.sectionTitle {
                // Only the actions reorder. Dragging an idea above another idea says nothing, and
                // a drag handle on a note is an affordance that leads nowhere.
                ReorderableStack(items: section.items, spacing: 2, isDragging: $reordering) { orderedIDs in
                    Task { await store.reorder(orderedIDs, within: section.items) }
                } row: { task in
                    taskRow(task)
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(section.items) { task in
                        taskRow(task)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private func taskRow(_ task: TaskItem) -> some View {
        TaskRowView(task: task, onEdit: nil) {
            Task { await store.toggleComplete(task) }
        }
        .contextMenu { TaskContextMenu(task: task, onFocus: { FocusTimer.shared.start(task: $0) }, onEdit: { editing = $0 }) }
        .swipeToDelete(id: task.id, onTap: { editing = task }) {
            Task { await TaskActions.delete(task) }
        }
    }

    private func tint(for kind: CaptureKind) -> Color {
        switch kind {
        case .task, .commitment: return Color.Offload.indigoText
        case .idea:              return Color.Offload.amber
        case .question:          return Color.Offload.teal
        case .waiting:           return Color.Offload.muted
        case .decision:          return Color.Offload.green
        case .event:             return Color.Offload.teal
        case .note, .reflection: return Color.Offload.muted
        }
    }

    // MARK: Subfolders, log, done

    private var subfoldersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Parts", systemImage: "folder.fill")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(Color.Offload.indigoText)
            ForEach(store.subfolders) { child in
                NavigationLink {
                    ProjectWorkspaceView(project: child.project)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.Offload.indigoText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.project.title)
                                .font(.Offload.taskTitle)
                                .foregroundStyle(Color.Offload.text)
                                .lineLimit(1)
                            Text(child.total == 0 ? "Empty" : "\(child.completed) of \(child.total) done")
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(Color.Offload.muted)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    /// The written record. Deliberately last and collapsed by default — it's the thing you consult,
    /// not the thing you act on, and a log at the top of a screen is a screen about the past.
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Log", systemImage: "list.bullet.rectangle")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Color.Offload.muted)
                Spacer(minLength: 0)
                Button { loggingUpdate = true } label: {
                    Image(systemName: "plus")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Color.Offload.muted)
                        .hitTarget(32)
                }
                .buttonStyle(.pressable(scale: 0.9))
                .accessibilityLabel("Add an update")
                if store.updates.count > 3 {
                    Button {
                        withAnimation(Motion.standard) { showingLog.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(.caption2, weight: .bold))
                            .rotationEffect(.degrees(showingLog ? 0 : -90))
                            .foregroundStyle(Color.Offload.muted)
                            .hitTarget(32)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel(showingLog ? "Collapse log" : "Expand log")
                }
            }

            if store.updates.isEmpty {
                Text("Nothing logged. Move the dot on the hill, or add a line about what changed.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(showingLog ? store.updates : Array(store.updates.prefix(3))) { update in
                    updateRow(update)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private func updateRow(_ update: ProjectUpdate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.Offload.muted.opacity(0.35))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                if let note = update.note, !note.isEmpty {
                    Text(note)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ProjectHill.label(update.hill))
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.text)
                }
                Text(relativeDate(update.createdAt))
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await store.deleteUpdate(update) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func relativeDate(_ iso: String) -> String {
        guard let date = DueDate.parse(iso) else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Done · \(doneItems.count)", systemImage: "checkmark.circle.fill")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(Color.Offload.green)
            VStack(spacing: 2) {
                ForEach(doneItems.prefix(12)) { task in
                    TaskRowView(task: task, onEdit: nil) {
                        Task { await store.toggleComplete(task) }
                    }
                }
            }
            if doneItems.count > 12 {
                Text("+ \(doneItems.count - 12) more")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "tray")
        } description: {
            Text("Capture a thought and mention this project and it'll land here — or add something directly.")
        } actions: {
            Button("Add an idea") { addingKind = .idea }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.Offload.indigo)
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // Every kind is addable directly, which is the point: jotting an idea into a
                // project has to be as cheap as adding a to-do, or everything gets typed as a
                // to-do because that was the box that happened to be open.
                Section("Add") {
                    ForEach(TaskContextMenu.assignableKinds) { kind in
                        Button { addingKind = kind } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                    Button { addingSubfolder = true } label: {
                        Label("Part of this project", systemImage: "folder.badge.plus")
                    }
                }
                Section {
                    Button { loggingUpdate = true } label: {
                        Label("Log an update", systemImage: "text.append")
                    }
                    Button { editingBrief = true } label: {
                        Label("Edit brief", systemImage: "square.and.pencil")
                    }
                    Button {
                        Task { await store.setArchived(!live.archived) }
                    } label: {
                        Label(live.archived ? "Unarchive" : "Archive",
                              systemImage: live.archived ? "tray.and.arrow.up" : "archivebox")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .accessibilityLabel("Project actions")
        }
    }
}
