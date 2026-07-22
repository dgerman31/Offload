import SwiftUI

/// A single planned session — the full prescription Gemini wrote: every exercise with its sets,
/// reps, and notes, mobility/stretching work called out separately from lifting work.
struct GymSessionDetailView: View {
    let session: WorkoutSession
    var store: GymStore

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    private var accent: Color { GymView.accent(for: session.workoutType) }
    private var lifting: [GymExercise] { session.exerciseList.filter { !$0.isMobility } }
    private var mobility: [GymExercise] { session.exerciseList.filter { $0.isMobility } }

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
                if let notes = session.notes, !notes.isEmpty {
                    section("Notes", icon: "note.text") {
                        Text(notes).font(.Offload.body).foregroundStyle(Color.Offload.text)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .background(Color.Offload.background)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await store.toggleComplete(session); dismiss() }
                    } label: {
                        Label(session.status == "completed" ? "Mark not done" : "Mark done",
                              systemImage: session.status == "completed" ? "arrow.uturn.backward" : "checkmark")
                    }
                    if session.status == "planned" {
                        Button {
                            Task { await store.skip(session); dismiss() }
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
                Task { await store.delete(session); dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(session.workoutType.capitalized)
                    .font(.caption).fontWeight(.bold)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(accent.opacity(0.16), in: .capsule)
                    .foregroundStyle(accent)
                Text("\(session.durationMinutes) min")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                if let minute = session.startMinute {
                    Text(Self.timeString(minute))
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
            }
            if !session.muscleGroupList.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(session.muscleGroupList, id: \.self) { group in
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

    private func exerciseRow(_ exercise: GymExercise) -> some View {
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
                    Text("rest \(rest)s").font(.Offload.data).foregroundStyle(Color.Offload.muted)
                }
            }
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(Color.Offload.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
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
