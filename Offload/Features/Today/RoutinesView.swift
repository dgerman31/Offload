import SwiftUI
import GRDB

/// Manage the repeating shape of your week: fixed classes and flexible habits.
struct RoutinesView: View {
    @State private var store = RoutineStore()
    @State private var adding = false

    var body: some View {
        List {
            if store.routines.isEmpty {
                ContentUnavailableView {
                    Label("No routines yet", systemImage: "repeat")
                } description: {
                    Text("Add the parts of your week that stay the same — a class that meets Mon/Wed/Fri, or a gym habit you want a few times a week and let Offload place on your lightest days.")
                } actions: {
                    Button("Add a routine") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                if !store.fixed.isEmpty {
                    Section("Fixed") {
                        ForEach(store.fixed) { routine in routineRow(routine) }
                            .onDelete { delete(store.fixed, $0) }
                    }
                }
                if !store.flexible.isEmpty {
                    Section {
                        ForEach(store.flexible) { routine in routineRow(routine) }
                            .onDelete { delete(store.flexible, $0) }
                    } header: {
                        Text("Flexible")
                    } footer: {
                        Text("Offload picks which days to fit these in — your lightest ones — and leaves the busiest as rest.")
                    }
                }
            }
        }
        .navigationTitle("Routines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add routine")
            }
        }
        .task { await store.observe() }
        .sheet(isPresented: $adding) {
            AddRoutineSheet { routine in Task { await store.create(routine) } }
        }
    }

    private func routineRow(_ routine: Routine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: routine.routineKind == .fixed ? "calendar" : "repeat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Offload.accent(for: routine.category))
                .frame(width: 32, height: 32)
                .background(Color.Offload.accent(for: routine.category).opacity(0.13),
                            in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text(routine.scheduleLabel)
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer(minLength: 0)
            if let cat = routine.category {
                Text(cat)
                    .font(.caption2).fontWeight(.medium)
                    .foregroundStyle(Color.Offload.accent(for: cat))
            }
        }
        .padding(.vertical, 2)
    }

    private func delete(_ list: [Routine], _ offsets: IndexSet) {
        for index in offsets where list.indices.contains(index) {
            let routine = list[index]
            Task { await store.delete(routine) }
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class RoutineStore {
    private(set) var routines: [Routine] = []

    var fixed: [Routine] { routines.filter { $0.routineKind == .fixed } }
    var flexible: [Routine] { routines.filter { $0.routineKind == .flexible } }

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try Routine.filter(Column("active") == true).order(Column("created_at")).fetchAll(db)
        }
        do {
            for try await rows in observation.values(in: db.dbQueue) { routines = rows }
        } catch { /* observation ended */ }
    }

    func create(_ routine: Routine) async {
        try? await db.dbQueue.write { try routine.insert($0) }
        Haptics.success()
        // Lay down today's instance immediately if it applies, so it shows without waiting for
        // the next app launch.
        await RoutineService.shared.materialize()
    }

    func delete(_ routine: Routine) async {
        var updated = routine
        updated.active = false
        let toSave = updated
        try? await db.dbQueue.write { try toSave.update($0) }
        Haptics.light()
    }
}

// MARK: - Add sheet

struct AddRoutineSheet: View {
    var onCreate: (Routine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = "Health"
    @State private var kind: Routine.Kind = .fixed
    @State private var weekdays: Set<Int> = [2, 4, 6]   // Mon/Wed/Fri
    @State private var hasTime = true
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var duration = 60
    @State private var timesPerWeek = 4
    @State private var flex = 1
    @FocusState private var titleFocused: Bool

    private let categories = HomeGrouping.categoryOrder
    /// Calendar weekday order Sun…Sat with short labels.
    private let weekdayOptions: [(num: Int, label: String)] =
        [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Practice of Medicine, Gym)", text: $title)
                        .focused($titleFocused)
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section {
                    Picker("Type", selection: $kind) {
                        Text("Fixed days").tag(Routine.Kind.fixed)
                        Text("A few times a week").tag(Routine.Kind.flexible)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind == .fixed
                         ? "Meets on set days at a set time — a class, a standing meeting."
                         : "You choose how often; Offload picks the best days and rests you on the busiest ones.")
                }

                if kind == .fixed {
                    Section("Which days") {
                        HStack(spacing: 8) {
                            ForEach(weekdayOptions, id: \.num) { option in
                                let on = weekdays.contains(option.num)
                                Button {
                                    if on { weekdays.remove(option.num) } else { weekdays.insert(option.num) }
                                    Haptics.light()
                                } label: {
                                    Text(option.label)
                                        .font(.system(.callout, design: .rounded)).fontWeight(.semibold)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(on ? Color.Offload.indigo : Color.Offload.muted.opacity(0.12),
                                                    in: .circle)
                                        .foregroundStyle(on ? .white : Color.Offload.text)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section("Time") {
                        Toggle("Set a start time", isOn: $hasTime)
                        if hasTime {
                            DatePicker("Starts", selection: $time, displayedComponents: [.hourAndMinute])
                        }
                    }
                } else {
                    Section("How often") {
                        Stepper("\(timesPerWeek) time\(timesPerWeek == 1 ? "" : "s") a week", value: $timesPerWeek, in: 1...7)
                        Stepper(flex > 0 ? "Up to \(timesPerWeek + flex) if there's room" : "No extra",
                                value: $flex, in: 0...3)
                    }
                }

                Section("How long") {
                    Picker("Duration", selection: $duration) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
            }
            .navigationTitle("New routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canSave)
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return kind == .flexible || !weekdays.isEmpty
    }

    private func add() {
        let cal = Calendar.current
        let startMinute: Int? = (kind == .fixed && hasTime)
            ? cal.component(.hour, from: time) * 60 + cal.component(.minute, from: time)
            : nil
        let routine = Routine(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            kind: kind,
            weekdays: kind == .fixed ? Array(weekdays) : [],
            startMinute: startMinute,
            durationMinutes: duration,
            timesPerWeek: kind == .flexible ? timesPerWeek : 0,
            flex: kind == .flexible ? flex : 0
        )
        onCreate(routine)
        dismiss()
    }
}
