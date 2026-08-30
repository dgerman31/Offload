import SwiftUI

/// The shape of your week, in one place: when you're awake, and which hours are already spoken
/// for.
///
/// Before this screen the planner knew exactly two things about a week — a start hour and an end
/// hour — and treated every minute between them as available. So the evening you actually study
/// in, or the hour you keep for the gym, read as open time and got filled with whatever needed a
/// slot. Everything that answers "how many hours do I have" (auto-fit, Plan my day, and the
/// overcommitment warnings to come) is only as good as this screen.
///
/// The waking window sits at the top rather than on the Scheduling section it also lives on,
/// because sleep is the one protected block that already exists — modelling it twice would give
/// two settings that have to agree, and eventually wouldn't.
struct MyWeekView: View {
    @AppStorage(DayPlanner.dayStartHourKey) private var dayStartHour = DayPlanner.defaultDayStartHour
    @AppStorage(DayPlanner.dayEndHourKey) private var dayEndHour = DayPlanner.defaultDayEndHour

    @State private var blocks: [ProtectedBlock] = ProtectedTime.stored()
    @State private var editing: ProtectedBlock?

    var body: some View {
        Form {
            Section {
                Picker("Awake from", selection: $dayStartHour) {
                    ForEach(4...12, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                }
                Picker("Until", selection: $dayEndHour) {
                    ForEach(15...23, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                }
            } header: {
                Text("Your day")
            } footer: {
                Text("Nothing is ever scheduled outside these hours, so sleep needs no block of its own.")
            }

            Section {
                if blocks.isEmpty {
                    emptyState
                } else {
                    ForEach(blocks) { block in
                        Button { editing = block } label: { row(block) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        blocks.remove(atOffsets: offsets)
                        persist()
                    }
                }
                Button {
                    editing = ProtectedBlock(title: "", weekdays: [2, 3, 4, 5, 6],
                                             startMinute: 18 * 60, endMinute: 19 * 60)
                } label: {
                    Label("Add a block", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Protected time")
            } footer: {
                Text(blocks.isEmpty
                     ? "Hours the planner must leave alone."
                     : "\(hoursProtected) hours a week the planner will schedule around.")
            }
        }
        .navigationTitle("My week")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { block in
            NavigationStack {
                ProtectedBlockEditor(block: block) { saved in
                    if let index = blocks.firstIndex(where: { $0.id == saved.id }) {
                        blocks[index] = saved
                    } else {
                        blocks.append(saved)
                    }
                    blocks.sort { $0.startMinute < $1.startMinute }
                    persist()
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every hour you're awake is currently fair game for the planner.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
            Button {
                blocks = ProtectedTime.suggestedDefaults()
                persist()
                Haptics.success()
            } label: {
                Label("Start with the usual", systemImage: "wand.and.stars")
                    .font(.caption).fontWeight(.semibold)
            }
            .buttonStyle(.pressable)
        }
        .padding(.vertical, 4)
    }

    private func row(_ block: ProtectedBlock) -> some View {
        HStack(spacing: 12) {
            Image(systemName: block.kind.symbol)
                .font(.system(.subheadline))
                .foregroundStyle(block.isEnabled ? Color.Offload.indigoText : Color.Offload.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title.isEmpty ? block.kind.label : block.title)
                    .font(.Offload.body)
                    .foregroundStyle(block.isEnabled ? Color.Offload.text : Color.Offload.muted)
                Text("\(ProtectedTime.describe(block.weekdays)) · \(ProtectedTime.describeTime(block))")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer(minLength: 8)
            if !block.isEnabled {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(Color.Offload.muted)
            }
        }
        .contentShape(Rectangle())
    }

    /// Protected hours per week — the number that makes the setting concrete, since "four blocks"
    /// says nothing about how much of a week is actually spoken for.
    private var hoursProtected: String {
        let minutes = blocks
            .filter(\.isEnabled)
            .reduce(0) { $0 + $1.minutes * $1.weekdays.count }
        return String(format: "%.0f", Double(minutes) / 60)
    }

    private func persist() {
        ProtectedTime.save(blocks)
    }

    static func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        var comps = DateComponents()
        comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? Date()
        return formatter.string(from: date)
    }
}

/// Add or edit one protected block. Times are picked, not typed — a `DatePicker` bound through
/// minutes-from-midnight, so what's stored stays a plain recurring offset rather than a date that
/// would silently mean something different next week.
struct ProtectedBlockEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProtectedBlock
    private let onSave: (ProtectedBlock) -> Void

    init(block: ProtectedBlock, onSave: @escaping (ProtectedBlock) -> Void) {
        _draft = State(initialValue: block)
        self.onSave = onSave
    }

    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]   // Mon-first, which is how a week reads

    var body: some View {
        Form {
            Section {
                TextField("What is it?", text: $draft.title)
                Picker("Kind", selection: $draft.kind) {
                    ForEach(ProtectedBlock.Kind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
            }

            Section("Days") {
                HStack(spacing: 6) {
                    ForEach(Self.weekdayOrder, id: \.self) { weekday in
                        dayToggle(weekday)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Section("Time") {
                DatePicker("From", selection: startBinding, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: endBinding, displayedComponents: .hourAndMinute)
                if draft.minutes <= 0 {
                    Label("The end needs to come after the start.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.Offload.amber)
                }
            }

            Section {
                Toggle("Apply this block", isOn: $draft.isEnabled)
            } footer: {
                Text("Turn it off to pause a block for a while without losing it.")
            }
        }
        .navigationTitle(draft.title.isEmpty ? "New block" : draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = draft
                    if saved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        saved.title = saved.kind.label
                    }
                    onSave(saved)
                    Haptics.success()
                    dismiss()
                }
                .disabled(draft.minutes <= 0 || draft.weekdays.isEmpty)
            }
        }
    }

    private func dayToggle(_ weekday: Int) -> some View {
        let on = draft.weekdays.contains(weekday)
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let label = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
        return Button {
            if on { draft.weekdays.remove(weekday) } else { draft.weekdays.insert(weekday) }
            Haptics.light()
        } label: {
            Text(label)
                .font(.system(.footnote, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(on ? Color.Offload.indigo : Color.Offload.surface, in: .circle)
                .foregroundStyle(on ? .white : Color.Offload.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // Minutes-from-midnight is the stored truth; a `DatePicker` needs a `Date`, so these two
    // bindings convert in both directions against today's midnight.
    private var startBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: draft.startMinute) },
                set: { draft.startMinute = Self.minutes(from: $0) })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: draft.endMinute) },
                set: { draft.endMinute = Self.minutes(from: $0) })
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .minute, value: minutes, to: startOfDay) ?? startOfDay
    }

    private static func minutes(from date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}
