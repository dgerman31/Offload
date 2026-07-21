import SwiftUI
import GRDB

/// Everything about one task, read-first.
///
/// Tapping a task used to drop you straight into a form of pickers, which is a strange answer
/// to "what is this?". This shows the thing itself — details, sub-steps with real progress,
/// who it involves, when it's due — with the actions you'd actually want, and editing one tap
/// away for when you genuinely want to change something.
struct TaskDetailView: View {
    let taskId: String

    @Environment(\.dismiss) private var dismiss
    @State private var store: TaskDetailStore
    @State private var editing = false
    @State private var focusing = false
    @State private var appeared = false
    @State private var newStep = ""

    init(task: TaskItem) {
        self.taskId = task.id
        _store = State(initialValue: TaskDetailStore(taskId: task.id, initial: task))
    }

    private var task: TaskItem { store.task }
    private var tint: Color { Color.Offload.accent(for: task.category) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header.appearIn(0, when: appeared)
                subtaskCard.appearIn(1, when: appeared).scrollAppear()
                metaCard.appearIn(2, when: appeared).scrollAppear()
                actionsCard.appearIn(3, when: appeared).scrollAppear()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.Offload.background)
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        .task { await store.observe() }
        .task { withAnimation(Motion.settle) { appeared = true } }
        .sheet(isPresented: $editing) {
            NavigationStack { TaskEditView(task: task) }
        }
        .fullScreenCover(isPresented: $focusing) {
            FocusSessionView(task: task, minutes: task.effortMinutes ?? 25)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    Task { await TaskActions.toggleComplete(task) }
                    Haptics.light()
                } label: {
                    Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(task.status == "completed" ? Color.Offload.green : tint)
                        .symbolEffect(.bounce, value: task.status)
                }
                .buttonStyle(.pressable(scale: 0.85))

                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .tracking(-0.4)
                        .foregroundStyle(Color.Offload.text)
                        .strikethrough(task.status == "completed", color: Color.Offload.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let details = task.descriptionText, !details.isEmpty {
                        Text(details)
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if !store.subtasks.isEmpty {
                progressBar
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard(cornerRadius: 20, elevation: .medium)
    }

    /// Rollup across sub-steps — a parent that says "2 of 5" is far more useful than one that
    /// looks identical whether you've started or not.
    private var progressBar: some View {
        let done = store.subtasks.filter { $0.status == "completed" }.count
        let total = store.subtasks.count
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(done) of \(total) done")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.Offload.data).fontWeight(.semibold)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: fraction))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.15))
                    Capsule().fill(tint).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 7)
            .animation(Motion.settle, value: fraction)
        }
    }

    // MARK: Subtasks

    private var subtaskCard: some View {
        card("Steps", icon: "list.bullet.indent", tint: tint) {
            VStack(spacing: 10) {
                subtaskList
                addStepField
            }
        }
    }

    private var subtaskList: some View {
        VStack(spacing: 10) {
            ForEach(store.subtasks) { sub in
                    Button {
                        Task { await TaskActions.toggleComplete(sub) }
                        Haptics.light()
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: sub.status == "completed" ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(sub.status == "completed" ? Color.Offload.green : Color.Offload.muted)
                            Text(sub.title)
                                .font(.Offload.body)
                                .foregroundStyle(sub.status == "completed" ? Color.Offload.muted : Color.Offload.text)
                                .strikethrough(sub.status == "completed", color: Color.Offload.muted)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.pressable(scale: 0.99))
            }
        }
    }

    /// Break a task down after the fact — the AI's decomposition is a starting point, not a
    /// verdict, and realising a task has steps usually happens once you're staring at it.
    private var addStepField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 15))
                .foregroundStyle(Color.Offload.muted)
            TextField("Add a step", text: $newStep)
                .font(.Offload.body)
                .submitLabel(.done)
                .onSubmit { Task { await addStep() } }
            if !newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") { Task { await addStep() } }
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(tint)
                    .buttonStyle(.pressable)
            }
        }
        .padding(.top, 2)
    }

    private func addStep() async {
        let title = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // Steps inherit their parent's context so they group and colour consistently.
        let step = TaskItem(
            title: title,
            category: task.category,
            priority: task.priority,
            parentTaskId: task.id,
            projectId: task.projectId,
            contextTags: task.contextTags
        )
        await TaskActions.create(step)
        newStep = ""
        Haptics.light()
    }

    // MARK: Meta

    private var metaCard: some View {
        card("Details", icon: "info.circle.fill", tint: Color.Offload.muted) {
            VStack(spacing: 10) {
                if let due = DueDate.parse(task.dueDate) {
                    metaRow("Due", TaskRowView.formatDue(task.dueDate ?? ""), icon: "calendar",
                            tint: due < Date() && task.status != "completed" ? Color.Offload.red : tint)
                }
                if let rule = Recurrence.parse(task.recurrenceRule) {
                    metaRow("Repeats", rule.describedPlainly, icon: "repeat", tint: Color.Offload.teal)
                }
                // Category and priority change in place — tap the row, pick, done. The whole point
                // is not having to open the editor just to bump something to high.
                Menu {
                    ForEach(CustomCategories.all(), id: \.self) { name in
                        Button {
                            Task { await TaskActions.setCategory(task, name) }; Haptics.light()
                        } label: {
                            Label(name, systemImage: task.category == name ? "checkmark" : "folder")
                        }
                    }
                } label: {
                    metaRow("Category", task.category ?? "Other", icon: "folder.fill", tint: tint,
                            interactive: true)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(["high", "medium", "low"], id: \.self) { level in
                        Button {
                            Task { await TaskActions.setPriority(task, level) }; Haptics.light()
                        } label: {
                            Label(level.capitalized, systemImage: task.priority == level ? "checkmark" : "flag")
                        }
                    }
                } label: {
                    metaRow("Priority", task.priority.capitalized, icon: "flag.fill",
                            tint: task.priority == "high" ? Color.Offload.red : Color.Offload.muted,
                            interactive: true)
                }
                .buttonStyle(.plain)
                if let effort = task.effortMinutes {
                    metaRow("Effort", DayPlanner.formatted(effort), icon: "timer", tint: Color.Offload.amber)
                }
                let people = People.decode(task.people)
                if !people.isEmpty {
                    metaRow("People", people.joined(separator: ", "), icon: "person.2.fill",
                            tint: Color.Offload.indigo)
                }
                if let project = store.projectTitle {
                    metaRow("Project", project, icon: "folder.badge.gearshape", tint: Color.Offload.indigo)
                }
            }
        }
    }

    private func metaRow(_ label: String, _ value: String, icon: String, tint: Color,
                         interactive: Bool = false) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 7, style: .continuous))
            Text(label)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.Offload.body).fontWeight(.medium)
                .foregroundStyle(Color.Offload.text)
                .multilineTextAlignment(.trailing)
            // A quiet affordance that this value is changeable right here, no Edit needed.
            if interactive {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.Offload.muted.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button { focusing = true } label: {
                Label("Focus \(task.effortMinutes ?? 25) min", systemImage: "timer")
                    .font(.Offload.taskTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.pressable)

            HStack(spacing: 10) {
                Menu {
                    ForEach(TaskActions.Snooze.allCases) { preset in
                        Button {
                            Task { await TaskActions.snooze(task, preset) }
                            Haptics.light()
                        } label: {
                            Label(preset.rawValue, systemImage: preset.icon)
                        }
                    }
                } label: {
                    Label("Snooze", systemImage: "clock.arrow.circlepath")
                        .font(.Offload.taskTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.Offload.muted.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.text)
                }

                Button(role: .destructive) {
                    Task {
                        await TaskActions.delete(task)
                        dismiss()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.Offload.taskTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.Offload.red.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.red)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func card<Content: View>(
        _ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2).fontWeight(.bold)
                .tracking(0.9)
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }
}

/// Observes a single task, its sub-steps and its project name, so the detail screen stays
/// live while you tick steps off inside it.
@MainActor
@Observable
final class TaskDetailStore {
    private(set) var task: TaskItem
    private(set) var subtasks: [TaskItem] = []
    private(set) var projectTitle: String?

    private let taskId: String
    private let db: AppDatabase

    init(taskId: String, initial: TaskItem, db: AppDatabase = .shared) {
        self.taskId = taskId
        self.task = initial
        self.db = db
    }

    func observe() async {
        let id = taskId
        let observation = ValueObservation.tracking { db -> (TaskItem?, [TaskItem], String?) in
            let current = try TaskItem.fetchOne(db, key: id)
            let children = try TaskItem
                .filter(Column("parent_task_id") == id)
                .filter(Column("deleted") == false)
                .order(Column("created_at"))
                .fetchAll(db)
            var projectName: String?
            if let projectId = current?.projectId {
                projectName = try Project.fetchOne(db, key: projectId)?.title
            }
            return (current, children, projectName)
        }
        do {
            for try await (current, children, projectName) in observation.values(in: db.dbQueue) {
                if let current { task = current }
                subtasks = children
                projectTitle = projectName
            }
        } catch {
            // Observation ended.
        }
    }
}
