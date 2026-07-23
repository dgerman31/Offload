import SwiftUI

/// A single planned session — the full prescription Gemini wrote: every exercise with its sets,
/// reps, and notes, mobility/stretching work called out separately from lifting work.
struct GymSessionDetailView: View {
    let session: WorkoutSession
    var store: GymStore

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var restTimer: RestTimerView.Config?

    private var accent: Color { GymView.accent(for: session.workoutType) }
    /// Read from the live store rather than the fixed `session` snapshot the sheet was opened
    /// with, so a set you just checked off stays checked when the view re-renders instead of
    /// reverting to whatever it looked like the moment this sheet appeared.
    private var current: WorkoutSession { store.sessions.first(where: { $0.id == session.id }) ?? session }
    private var lifting: [GymExercise] { current.exerciseList.filter { !$0.isMobility } }
    private var mobility: [GymExercise] { current.exerciseList.filter { $0.isMobility } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !lifting.isEmpty {
                    section("Exercises", icon: "dumbbell.fill") {
                        VStack(spacing: 10) { ForEach(lifting) { exerciseRow($0) } }
                    }
                }
                if !mobility.isEmpty {
                    section("Mobility & Stretching", icon: "figure.flexibility") {
                        VStack(spacing: 10) { ForEach(mobility) { exerciseRow($0) } }
                    }
                }
                if let notes = current.notes, !notes.isEmpty {
                    section("Notes", icon: "note.text") {
                        Text(notes).font(.Offload.body).foregroundStyle(Color.Offload.text)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .background(Color.Offload.background)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await store.toggleComplete(current); dismiss() }
                    } label: {
                        Label(current.status == "completed" ? "Mark not done" : "Mark done",
                              systemImage: current.status == "completed" ? "arrow.uturn.backward" : "checkmark")
                    }
                    if current.status == "planned" {
                        Button {
                            Task { await store.skip(current); dismiss() }
                        } label: {
                            Label("Skip — push the rest of the week forward", systemImage: "arrow.uturn.forward")
                        }
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await store.delete(current); dismiss() }
            }
        }
        .sheet(item: $restTimer) { config in
            RestTimerView(seconds: config.seconds, accent: config.accent)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(current.workoutType.capitalized)
                    .font(.caption).fontWeight(.bold)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(accent.opacity(0.16), in: .capsule)
                    .foregroundStyle(accent)
                Text("\(current.durationMinutes) min")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                if let minute = current.startMinute {
                    Text(Self.timeString(minute))
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
            }
            if !current.muscleGroupList.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(current.muscleGroupList, id: \.self) { group in
                        Text(group)
                            .font(.caption2).fontWeight(.semibold)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.Offload.divider, in: .capsule)
                            .foregroundStyle(Color.Offload.muted)
                    }
                }
            }
        }
    }

    /// One exercise, now something to actually log against mid-workout rather than just read:
    /// a dot per prescribed set (tap to mark sets 1…N done, tap the last filled one again to back
    /// off a mis-tap), an editable "actual" weight field, and — when the plan names a rest
    /// interval — a button that starts a countdown instead of just stating the number.
    private func exerciseRow(_ exercise: GymExercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    HStack(spacing: 10) {
                        if let sets = exercise.sets, let reps = exercise.reps {
                            Text("\(sets) × \(reps)").font(.Offload.data).foregroundStyle(accent)
                        } else if let reps = exercise.reps {
                            Text(reps).font(.Offload.data).foregroundStyle(accent)
                        }
                        if let weight = exercise.weightNote {
                            Text(weight).font(.Offload.data).foregroundStyle(Color.Offload.muted)
                        }
                        if let rest = exercise.restSeconds {
                            Button {
                                restTimer = RestTimerView.Config(seconds: rest, accent: accent)
                            } label: {
                                Label("rest \(rest)s", systemImage: "timer")
                                    .font(.Offload.data)
                                    .foregroundStyle(accent)
                            }
                            .buttonStyle(.pressable(scale: 0.94))
                        }
                    }
                    if let notes = exercise.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(Color.Offload.muted)
                    }
                }
                Spacer(minLength: 8)
                if exercise.isLogged {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.Offload.green)
                }
            }

            if let sets = exercise.sets, sets > 0 {
                setDots(exercise, sets: sets)
            }

            WeightLogField(exercise: exercise, session: current, store: store)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .animation(Motion.snappy, value: exercise.completedSets)
    }

    /// Tap set N to mark sets 1...N done; tap the last already-filled dot again to undo one.
    private func setDots(_ exercise: GymExercise, sets: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(1...sets, id: \.self) { number in
                let done = number <= exercise.completedSets
                Button {
                    let target = number == exercise.completedSets ? number - 1 : number
                    Haptics.light()
                    Task { await store.logExercise(exercise.id, in: current) { $0.completedSets = target } }
                } label: {
                    Circle()
                        .fill(done ? accent : accent.opacity(0.15))
                        .frame(width: 22, height: 22)
                        .overlay {
                            if done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.pressable(scale: 0.85))
            }
            Text("\(exercise.completedSets)/\(sets) sets")
                .font(.caption).foregroundStyle(Color.Offload.muted)
                .padding(.leading, 2)
        }
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2).fontWeight(.bold).tracking(0.8)
                .foregroundStyle(Color.Offload.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .offloadCard()
    }

    static func timeString(_ minute: Int) -> String {
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return df.string(from: date)
    }
}

/// What you actually used, editable inline — defaults to showing the plan's own note as a
/// placeholder until you log something different. Owns its own draft text rather than writing
/// through to the store on every keystroke: a round-trip through the database and back on each
/// character risks the field's content getting reset mid-type from a lagging or out-of-order
/// write, so this only commits once you stop editing (submit, or tapping away).
private struct WeightLogField: View {
    let exercise: GymExercise
    let session: WorkoutSession
    var store: GymStore

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scalemass")
                .font(.system(size: 12))
                .foregroundStyle(Color.Offload.muted)
            TextField(exercise.weightNote ?? "Log actual weight", text: $draft)
                .font(.caption)
                .foregroundStyle(Color.Offload.text)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
        .onAppear { draft = exercise.loggedWeightNote ?? "" }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (exercise.loggedWeightNote ?? "") else { return }
        Task {
            await store.logExercise(exercise.id, in: session) {
                $0.loggedWeightNote = trimmed.isEmpty ? nil : trimmed
            }
        }
    }
}
