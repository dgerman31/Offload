import SwiftUI
import GRDB

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
    @State private var hasTime = false
    @State private var dueDate: Date
    @State private var projectId: String?
    @State private var recurrence: RecurrenceChoice = .none
    @State private var projects = ProjectStore()
    @FocusState private var titleFocused: Bool

    private var categories: [String] { CustomCategories.all() }
    private let priorities = ["high", "medium", "low"]

    /// A date phrase spotted in the title, offered but never auto-applied.
    private var detected: QuickDate.Match? {
        guard !hasDueDate else { return nil }   // they've already chosen a time
        return QuickDate.parse(title)
    }

    private func apply(_ match: QuickDate.Match) {
        title = match.cleanedTitle
        dueDate = match.date
        hasDueDate = true
        // "tomorrow 1pm" is a commitment; bare "tomorrow" is a day, and inventing an hour for
        // it would make the planner treat it as fixed.
        hasTime = match.hasTime
    }

    static func friendly(_ date: Date, hasTime: Bool) -> String {
        let df = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            df.dateFormat = hasTime ? "'today' h:mm a" : "'today'"
        } else if Calendar.current.isDateInTomorrow(date) {
            df.dateFormat = hasTime ? "'tomorrow' h:mm a" : "'tomorrow'"
        } else {
            df.dateFormat = hasTime ? "MMM d, h:mm a" : "MMM d"
        }
        return df.string(from: date)
    }

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
                    // Typing "tomorrow 1pm" offers to schedule it — never silently rewrites
                    // what you typed, since guessing wrong on someone's own words is worse
                    // than making them tap once.
                    if let detected {
                        Button {
                            withAnimation(Motion.standard) { apply(detected) }
                            Haptics.light()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars")
                                    .foregroundStyle(Color.Offload.indigo)
                                Text("Schedule for \(Self.friendly(detected.date, hasTime: detected.hasTime))")
                                    .font(.Offload.body)
                                    .foregroundStyle(Color.Offload.text)
                                Spacer(minLength: 0)
                                Text("Use")
                                    .font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(Color.Offload.indigo)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    TextField("Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...8)
                }

                Section {
                    Toggle("Schedule it", isOn: $hasDueDate.animation(Motion.standard))
                    if hasDueDate {
                        // A day and a time are different commitments — "Friday" shouldn't
                        // silently become "Friday at 9am" and get treated as fixed.
                        Toggle("Set a specific time", isOn: $hasTime.animation(Motion.standard))
                        DatePicker(hasTime ? "When" : "Day", selection: $dueDate,
                                   displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                        Picker("Repeat", selection: $recurrence) {
                            ForEach(RecurrenceChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                } header: {
                    Text("When")
                } footer: {
                    if hasDueDate && !hasTime {
                        Text("Without a time this stays flexible, so Plan my day can find it a slot.")
                    } else if hasDueDate {
                        Text("With a time this is a commitment — Plan my day will schedule around it, never move it.")
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

    /// A whole-day task is stored at the start of that day; the flag carries the meaning, so
    /// the stored hour is never mistaken for an intention.
    private var storedDueDate: Date {
        hasTime ? dueDate : Calendar.current.startOfDay(for: dueDate)
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
            dueDate: hasDueDate ? DueDate.canonicalString(from: storedDueDate) : nil,
            dueDateConfidence: hasDueDate ? 1.0 : nil,   // typed by hand = certain
            recurrenceRule: hasDueDate ? recurrence.rrule : nil,
            dueIsAllDay: hasDueDate && !hasTime,
            // A time you chose by hand is a commitment — it anchors the day, never reflows.
            pinned: hasDueDate && hasTime
        )

        // The same auto-fit a captured task already gets: undated work, or work you scheduled
        // for today without picking a specific time, gets a real slot in today's open time right
        // away — instead of sitting unplaced until something else happens to plan the day. A
        // future day or a specific chosen time is left exactly as you set it (AutoFit only ever
        // touches today's flexible work).
        let existing = (try? await AppDatabase.shared.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        let fitted = AutoFit.fitIntoToday(new: [task], existing: existing).first ?? task

        await TaskActions.create(fitted)
        Haptics.success()
        dismiss()
    }
}
