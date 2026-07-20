import SwiftUI

/// Edit a task's title, details, category, priority, due date, and project. Saving logs
/// corrections so the app can learn the user's preferences over time (spec §4,
/// correction-driven adaptation).
///
/// The title stays a short action phrase; everything specific lives in **Details**, so tasks
/// read cleanly in lists while keeping all their context one tap away.
struct TaskEditView: View {
    let original: TaskItem
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var details: String
    @State private var category: String
    @State private var priority: String
    @State private var hasDueDate: Bool
    @State private var hasTime: Bool
    @State private var dueDate: Date
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var projectId: String?
    @State private var projects = ProjectStore()

    private var categories: [String] { CustomCategories.all() }
    private let priorities = ["high", "medium", "low"]

    init(task: TaskItem) {
        self.original = task
        _title = State(initialValue: task.title)
        _details = State(initialValue: task.descriptionText ?? "")
        _category = State(initialValue: task.category ?? "Other")
        _priority = State(initialValue: task.priority)
        let parsed = DueDate.parse(task.dueDate)
        _hasDueDate = State(initialValue: parsed != nil)
        _hasTime = State(initialValue: parsed != nil && !task.dueIsAllDay)
        _dueDate = State(initialValue: parsed ?? Date())
        let parsedDeadline = DueDate.parse(task.deadline)
        _hasDeadline = State(initialValue: parsedDeadline != nil)
        _deadline = State(initialValue: parsedDeadline ?? Date())
        _projectId = State(initialValue: task.projectId)
    }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $title, axis: .vertical)
            }
            Section {
                TextField("Anything worth remembering about this…", text: $details, axis: .vertical)
                    .lineLimit(3...12)
            } header: {
                Text("Details")
            } footer: {
                Text("Keep the title short and put the specifics here — names, numbers, context.")
            }
            Section("Project") {
                Picker("Project", selection: $projectId) {
                    Text("None").tag(String?.none)
                    ForEach(projects.allProjects) { project in
                        Text(project.title).tag(String?.some(project.id))
                    }
                }
            }
            Section("Category") {
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Priority") {
                Picker("Priority", selection: $priority) {
                    ForEach(priorities, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Scheduled", isOn: $hasDueDate.animation(Motion.standard))
                if hasDueDate {
                    Toggle("Specific time", isOn: $hasTime.animation(Motion.standard))
                    DatePicker(hasTime ? "When" : "Day", selection: $dueDate,
                               displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                }
            } header: {
                Text("When you'll do it")
            } footer: {
                Text(hasDueDate && hasTime
                     ? "A committed time. Plan my day will work around it rather than move it."
                     : "Leave the time off to keep this flexible so it can be planned into a free slot.")
            }

            Section {
                Toggle("Has a deadline", isOn: $hasDeadline.animation(Motion.standard))
                if hasDeadline {
                    DatePicker("Due by", selection: $deadline, displayedComponents: [.date])
                }
            } header: {
                Text("Deadline")
            } footer: {
                Text("A due date is not a do date — you might start something Monday that isn't due until Friday.")
            }
        }
        .navigationTitle("Edit task")
        .navigationBarTitleDisplayMode(.inline)
        .task { await projects.observe() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() async {
        var edited = original
        edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.descriptionText = trimmedDetails.isEmpty ? nil : trimmedDetails
        edited.category = category
        edited.priority = priority
        edited.projectId = projectId
        if hasDueDate {
            // Store a whole-day intention at the start of that day; the flag carries the
            // meaning so the hour is never mistaken for a commitment.
            let stored = hasTime ? dueDate : Calendar.current.startOfDay(for: dueDate)
            edited.dueDate = DueDate.canonicalString(from: stored)
            edited.dueDateConfidence = 1.0   // user-specified = certain
            edited.dueIsAllDay = !hasTime
        } else {
            edited.dueDate = nil
            edited.dueDateConfidence = nil
            edited.dueIsAllDay = false
        }
        edited.deadline = hasDeadline
            ? DueDate.canonicalString(from: Calendar.current.startOfDay(for: deadline))
            : nil
        await TaskEditService.save(edited, original: original)
        dismiss()
    }
}
