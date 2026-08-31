import SwiftUI

/// The short setup that gives the AI a picture of your life.
///
/// Four questions, one per screen, every one skippable. It is deliberately not a form: a form of
/// six text areas gets abandoned at the second one, and a half-filled brief is worth much less than
/// a short complete one. Anything skipped here comes back later as a single question from
/// `LifeBriefInterview`, at a moment when the app has a reason to ask.
///
/// Reachable from Settings at any time, so this is a screen you can return to rather than a gate
/// you pass through once.
struct LifeBriefSetupView: View {
    var onFinished: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var brief = LifeBrief.stored()
    @State private var step = 0
    @FocusState private var writing: Bool

    /// The order asked. Not the same as the order they're stored in: what you're working toward is
    /// the single most useful sentence the model can have, so it's first while attention is highest.
    private let steps: [LifeBriefQuestion] = [
        LifeBriefInterview.questions.first { $0.id == "who" } ?? LifeBriefInterview.questions[0],
        LifeBriefInterview.questions.first { $0.id == "workingToward" } ?? LifeBriefInterview.questions[0],
        LifeBriefInterview.questions.first { $0.id == "normalWeek" } ?? LifeBriefInterview.questions[0],
        LifeBriefInterview.questions.first { $0.id == "avoid" } ?? LifeBriefInterview.questions[0]
    ]

    private var current: LifeBriefQuestion { steps[min(step, steps.count - 1)] }
    private var isLast: Bool { step >= steps.count - 1 }

    private var answer: Binding<String> {
        Binding(
            get: { LifeBriefInterview.value(of: current.field, in: brief) },
            set: { brief = LifeBriefInterview.apply($0, to: current.field, in: brief) }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                ProgressView(value: Double(step + 1), total: Double(steps.count))
                    .tint(Color.Offload.indigo)

                Text(current.prompt)
                    .font(.Offload.manrope(26, .bold, relativeTo: .title))
                    .foregroundStyle(Color.Offload.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(current.id)          // cross-fade between questions rather than mutating one
                    .transition(.opacity)

                TextField("", text: answer, prompt: Text(current.placeholder), axis: .vertical)
                    .font(.Offload.body)
                    .lineLimit(3...8)
                    .focused($writing)
                    .padding(14)
                    .background(Color.Offload.surface, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.Offload.hairline, lineWidth: 0.5)
                    )
                    .id(current.id)

                Text("Everything here stays on this iPhone except where it's sent with a capture, and you can read, edit or delete all of it in Settings.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Offload.background)
            .animation(Motion.standard, value: step)
            .navigationTitle("About you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == 0 ? "Not now" : "Back") {
                        if step == 0 { finish() } else { withAnimation(Motion.standard) { step -= 1 } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLast ? "Done" : "Next") {
                        if isLast { finish() } else { withAnimation(Motion.standard) { step += 1 } }
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isLast {
                    Button("Skip this one") {
                        withAnimation(Motion.standard) { step += 1 }
                    }
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                writing = true
            }
        }
    }

    private func finish() {
        LifeBrief.save(brief)
        Haptics.success()
        onFinished?()
        dismiss()
    }
}

/// The whole brief, readable and editable, with the one-tap way to delete it.
///
/// The same contract `LearnedProfileView` gives the learning layer: if the app is going to carry a
/// picture of someone around and send it to a model, that person has to be able to read exactly
/// what it says and disagree with it.
struct LifeBriefView: View {
    @State private var brief = LifeBrief.stored()
    @State private var confirmingForget = false
    @State private var runningSetup = false

    var body: some View {
        Form {
            Section {
                Text("This is prepended to what the AI reads whenever it sorts a capture or plans your day. It's why it knows that \"AmBoss\" is study and not admin, and why it doesn't put work at 6am if you've said mornings are dead.")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
            }

            field("Who I am", text: $brief.who, placeholder: "Third-year medical student, currently on rotations")
            field("What I'm working toward", text: $brief.workingToward, placeholder: "Step 1 in May, and the research project alongside it")
            field("A normal week", text: $brief.normalWeek, placeholder: "Lectures Mon–Thu mornings, clinic Friday")
            field("People", text: $brief.people, placeholder: "Dr. Okafor is my PI; Sam is my study partner")
            field("How I work", text: $brief.howIWork, placeholder: "Mornings are sharp; anything after 9pm is wasted")
            field("What Offload shouldn't do", text: $brief.avoid, placeholder: "Never schedule anything before 8am")

            if !brief.observations.isEmpty {
                Section {
                    ForEach(Array(brief.observations.enumerated()), id: \.offset) { _, observation in
                        Text(observation)
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.text)
                    }
                    .onDelete { offsets in
                        brief.observations.remove(atOffsets: offsets)
                        LifeBrief.save(brief)
                    }
                } header: {
                    Text("What Offload noticed")
                } footer: {
                    Text("Things the app worked out and you confirmed. Swipe to remove any that aren't right.")
                }
            }

            Section {
                Button {
                    runningSetup = true
                } label: {
                    Label("Run the short setup again", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    confirmingForget = true
                } label: {
                    Label("Forget all of this", systemImage: "trash")
                }
                .disabled(brief.isEmpty)
            } footer: {
                Text("Forgetting leaves the app working exactly as it did before you filled this in — a little less sure about what you mean.")
            }
        }
        .navigationTitle("About you")
        .navigationBarTitleDisplayMode(.inline)
        // Saved on the way out rather than on every keystroke: a `Form` binding fires per character,
        // and re-encoding the whole brief that often is work for nothing.
        .onDisappear { LifeBrief.save(brief) }
        .sheet(isPresented: $runningSetup, onDismiss: { brief = LifeBrief.stored() }) {
            LifeBriefSetupView()
        }
        .confirmationDialog("Forget everything in your brief?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget it all", role: .destructive) {
                LifeBrief.forget()
                brief = LifeBrief()
                Haptics.warning()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone, and the AI goes back to reading your captures without any context about you.")
        }
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        Section(title) {
            TextField("", text: text, prompt: Text(placeholder), axis: .vertical)
                .font(.Offload.body)
                .lineLimit(2...8)
        }
    }
}

/// The occasional single question, shown inline rather than as a modal.
///
/// One at a time, spaced days apart, and never a queue — see `LifeBriefInterview`. It appears where
/// it is least in the way and most likely to be true: the morning screen, under the plan, at the
/// one moment of the day the app already has your attention for something reflective.
struct LifeBriefQuestionCard: View {
    let question: LifeBriefQuestion
    /// Handed the typed answer. The card never writes the brief itself — a view that owns a copy of
    /// persisted state is how two writers appear, and this one already has a writer.
    var onAnswered: (String) -> Void
    var onDismissed: () -> Void

    @State private var answer = ""
    @State private var expanded = false
    @FocusState private var writing: Bool

    private var trimmed: String { answer.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Color.Offload.indigoText)
                    .padding(.top, 2)
                Text(question.prompt)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Haptics.light()
                    onDismissed()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(Color.Offload.muted)
                        .hitTarget(32)
                }
                .buttonStyle(.pressable(scale: 0.9))
                .accessibilityLabel("Don't ask this")
            }

            if expanded {
                TextField("", text: $answer, prompt: Text(question.placeholder), axis: .vertical)
                    .font(.Offload.body)
                    .lineLimit(2...5)
                    .focused($writing)
                    .padding(12)
                    .background(Color.Offload.background, in: .rect(cornerRadius: 12, style: .continuous))
                HStack {
                    Spacer(minLength: 0)
                    Button("Save") {
                        writing = false
                        onAnswered(trimmed)
                    }
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
                    .buttonStyle(.pressable)
                    .disabled(trimmed.isEmpty)
                }
            } else {
                Button {
                    withAnimation(Motion.standard) { expanded = true }
                } label: {
                    Text("Answer")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.indigoText)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
        .task(id: expanded) {
            guard expanded else { return }
            try? await Task.sleep(for: .milliseconds(180))
            writing = true
        }
    }

}
