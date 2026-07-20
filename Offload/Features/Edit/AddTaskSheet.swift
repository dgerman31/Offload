import SwiftUI

/// Type a task directly, no AI involved. Capture-by-voice is the app's headline act, but
/// sometimes you already know exactly what you want and typing it is simply faster — and an
/// organizer you can't add to by hand feels broken.
///
/// Defaults are deliberately generous: pick a day from the strip and it's scheduled; leave it
/// and the task just sits in "whenever".
struct AddTaskSheet: View {
    /// Pre-selected day (e.g. the day you were looking at in Calendar).
    var initialDate: Date?
    var initialProjectId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var category = "Personal"
    @State private var priority = "medium"
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var projectId: String?
    @State private var recurrence: RecurrenceChoice = .none
    @State private var projects = ProjectStore()
    @FocusState private var titleFocused: Bool

    private let categories = HomeGrouping.categoryOrder
    private let priorities = ["high", "medium", "low"]

    /// The handful of repeat rules worth one tap; anything more exotic can be dictated.
    enum RecurrenceChoice: String, CaseIterable, Identifiable {
        case none = "Never"
        case daily = "Every day"
        case weekly = "Every week"
        case weekdays = "Weekdays"
        case monthly = "Every month"

        var id: String { rawValue }

        var rrule: String? {
            switch self {
            case .none:     return nil
            case .daily:    return "FREQ=DAILY"
            case .weekly:   return "FREQ=WEEKLY"
            case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
            case .monthly:  return "FREQ=MONTHLY"
            }
        }
    }

    init(initialDate: Date? = nil, initialProjectId: String? = nil) {
        self.initialDate = initialDate
        self.initialProjectId = initialProjectId
        _hasDueDate = State(initialValue: initialDate != nil)
        // Default to 9am on the chosen day rather than "right now", which is rarely meant.
        let base = initialDate ?? Date()
        _dueDate = State(initialValue: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base)
        _projectId = State(initialValue: initialProjectId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $title, axis: .vertical)
                        .font(.Offload.taskTitle)
                        .focused($titleFocused)
                }
                Section {
                    TextField("Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...8)
                }

                Section("When") {
                    Toggle("Schedule it", isOn: $hasDueDate.animation(Motion.standard))
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate)
                        Picker("Repeat", selection: $recurrence) {
                            ForEach(RecurrenceChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                }

                Section("Organize") {
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { name in
                            Label(name, systemImage: "circle.fill")
                                .foregroundStyle(Color.Offload.accent(for: name))
                                .tag(name)
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(priorities, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Project", selection: $projectId) {
                        Text("None").tag(String?.none)
                        ForEach(projects.allProjects) { project in
                            Text(project.title).tag(String?.some(project.id))
                        }
                    }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .task { await projects.observe() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    private func add() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        let task = TaskItem(
            title: trimmedTitle,
            descriptionText: trimmedDetails.isEmpty ? nil : trimmedDetails,
            category: category,
            priority: priority,
            projectId: projectId,
            dueDate: hasDueDate ? DueDate.canonicalString(from: dueDate) : nil,
            dueDateConfidence: hasDueDate ? 1.0 : nil,   // typed by hand = certain
            recurrenceRule: hasDueDate ? recurrence.rrule : nil
        )
        await TaskActions.create(task)
        Haptics.success()
        dismiss()
    }
}
