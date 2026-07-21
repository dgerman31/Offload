import SwiftUI

/// The capture screen (spec §5.5). Text-first: you can always type. Voice is added as an
/// additional mode in increment 4b. Save runs the on-device extraction pipeline and
/// reports how many tasks were added; failures keep your words and offer a retry.
struct CaptureView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CaptureViewModel()
    @State private var pulse = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .editing, .processing:
                    editor
                case let .reviewingDuplicates(candidates):
                    duplicateReview(candidates)
                case let .done(added, titles, project, similar):
                    successView(added: added, titles: titles, project: project, similar: similar)
                case let .failed(message):
                    failureView(message: message)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.Offload.background)
            .navigationTitle("Quick Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                // Opened via the Action Button? Start recording immediately (spec §2.3).
                // Any other entry (HomeView taps) stays typing-first and focuses the keyboard.
                if capture.consumeAutoListen() {
                    Task { await vm.beginAutoListen() }
                } else {
                    fieldFocused = true
                }
            }
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What's on your mind?")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(Color.Offload.text)

            TextField("Speak or type a passing thought…", text: $vm.text, axis: .vertical)
                .font(.Offload.body)
                .lineLimit(3...12)
                .focused($fieldFocused)
                .disabled(vm.isProcessing)
                .padding(16)
                .offloadCard(cornerRadius: 18)
                // A live ring while dictating, so the mic never feels ambiguous.
                .overlay(alignment: .topTrailing) {
                    if vm.isListening {
                        WaveformView(level: vm.inputLevel).padding(14)
                    }
                }

            // Voice is an *additional* input — the text field above always works too.
            HStack(spacing: 12) {
                Button {
                    Task { await vm.toggleMic() }
                } label: {
                    Label(vm.isListening ? "Listening… tap to finish" : "Speak instead",
                          systemImage: vm.isListening ? "waveform.circle.fill" : "mic.fill")
                        .font(.Offload.taskTitle)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(vm.isListening ? Color.Offload.teal : Color.Offload.surface,
                                    in: .capsule)
                        .foregroundStyle(vm.isListening ? .white : Color.Offload.indigo)
                        .overlay(Capsule().stroke(Color.Offload.divider, lineWidth: vm.isListening ? 0 : 1))
                }
                .disabled(vm.isProcessing)
                .accessibilityLabel(vm.isListening ? "Stop dictation" : "Start dictation")

                // Distinct from the mic capsule (which stops AND submits): "Type instead"
                // stops the mic WITHOUT submitting, so an auto-record session can be reviewed,
                // edited, or extended by typing before a manual Save (spec §2.3).
                if vm.isListening {
                    Button {
                        vm.stopListening()
                        fieldFocused = true
                        Haptics.light()
                    } label: {
                        Label("Type instead", systemImage: "keyboard")
                            .font(.Offload.taskTitle)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Color.Offload.surface, in: .capsule)
                            .foregroundStyle(Color.Offload.indigo)
                            .overlay(Capsule().stroke(Color.Offload.divider, lineWidth: 1))
                    }
                    .accessibilityLabel("Type instead — stop the mic without saving")
                }
                Spacer()
            }

            if vm.isProcessing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Organizing…")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                }
                .transition(.opacity)
            }
            Spacer()
        }
        .animation(Motion.standard, value: vm.isListening)
        .animation(Motion.standard, value: vm.isProcessing)
    }

    /// Breathing ring shown while the mic is live.
    private var listeningPulse: some View {
        ZStack {
            Circle()
                .fill(Color.Offload.teal.opacity(0.18))
                .frame(width: 26, height: 26)
                .scaleEffect(pulse ? 1.35 : 0.9)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Color.Offload.teal)
                .frame(width: 9, height: 9)
        }
        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
        .accessibilityHidden(true)
    }

    // MARK: Duplicate review — block before saving (spec §3.5)

    /// Near-duplicates must be resolved before anything is written: each candidate offers
    /// Merge / Keep both / Skip, and Save stays disabled until every choice is made.
    private func duplicateReview(_ candidates: [DuplicateCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Possible duplicates", systemImage: "doc.on.doc.fill")
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            Text("Some of these look like tasks you already have. Choose what to do with each before saving.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(candidates) { candidate in
                        duplicateCard(candidate)
                    }
                }
            }

            Button {
                Task { await vm.confirmResolutions() }
            } label: {
                Text("Save")
                    .font(.Offload.taskTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(vm.allDuplicatesResolved ? Color.Offload.indigo : Color.Offload.muted.opacity(0.4),
                                in: .capsule)
                    .foregroundStyle(.white)
            }
            .disabled(!vm.allDuplicatesResolved)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duplicateCard(_ candidate: DuplicateCandidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(candidate.newTitle, systemImage: "sparkles")
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text("looks similar to existing “\(candidate.existingTitle)”")
                    .font(.caption)
                    .foregroundStyle(Color.Offload.amber)
            }

            HStack(spacing: 8) {
                resolutionButton(candidate, .merge, "Merge", "arrow.triangle.merge")
                resolutionButton(candidate, .keepBoth, "Keep both", "plus.square.on.square")
                resolutionButton(candidate, .skip, "Skip", "xmark")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.Offload.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Offload.divider, lineWidth: 1))
    }

    private func resolutionButton(_ candidate: DuplicateCandidate,
                                  _ resolution: DuplicateResolution,
                                  _ title: String,
                                  _ symbol: String) -> some View {
        let selected = vm.resolutions[candidate.id] == resolution
        return Button {
            vm.resolve(candidate, as: resolution)
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption).fontWeight(.semibold)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Color.Offload.indigo : Color.Offload.background, in: .capsule)
                .foregroundStyle(selected ? .white : Color.Offload.indigo)
                .overlay(Capsule().stroke(Color.Offload.divider, lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) for \(candidate.newTitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Success

    /// What the success screen leads with — "Created project X" when a command made only a
    /// container, otherwise a task count.
    private func headline(added: Int, project: String?) -> String {
        if added == 0, let project { return "Created “\(project)”" }
        return added == 1 ? "Added 1 task" : "Added \(added) tasks"
    }

    private func successView(added: Int, titles: [String], project: String?, similar: [String]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.Offload.teal)
            // "Create a project" with nothing else made a container, not tasks — say so.
            Text(headline(added: added, project: project))
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            if let project, added > 0 {
                Text("Project “\(project)”")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
            }
            // Show what the AI actually understood — instant feedback on the extraction.
            if !titles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(titles, id: \.self) { title in
                        Label(title, systemImage: "circle")
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.text)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.Offload.surface, in: .rect(cornerRadius: 12))
            }
            // Quick-tap refinements (only when the model flagged real ambiguity). A confident
            // capture shows none and saves with zero taps — exactly like before.
            if !vm.chips.isEmpty {
                chipRow
            }
            // Dedup surface (spec §3.5): similar existing tasks — informed, never silent.
            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(similar, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.Offload.amber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { finish() }
                .font(.Offload.taskTitle)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Color.Offload.indigo, in: .capsule)
                .foregroundStyle(.white)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        // Auto-dismiss timing scales with how much there is to read; stay longer on warnings.
        // With refinement chips present we DON'T auto-dismiss — the user needs time to tap — so
        // the sheet waits for an explicit Done. Tapping every chip lets the timer resume.
        .task(id: vm.chips.count) {
            guard !vm.hasChips else { return }
            let seconds = min(5.0, 1.6 + Double(titles.count) * 0.5 + Double(similar.count) * 1.0)
            try? await Task.sleep(for: .seconds(seconds))
            finish()
        }
    }

    /// A single wrapping row of tappable refinement pills. Each tap patches the just-saved
    /// task(s) locally and clears its question group; the row disappears when none remain.
    private var chipRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Refine", systemImage: "wand.and.stars")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(Color.Offload.muted)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(vm.chips) { chip in
                    Button {
                        Task { await vm.applyChip(chip) }
                    } label: {
                        Text(chip.label)
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.Offload.surface, in: .capsule)
                            .foregroundStyle(Color.Offload.indigo)
                            .overlay(Capsule().stroke(Color.Offload.divider, lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Refine: \(chip.label)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(Motion.standard, value: vm.chips.count)
    }

    // MARK: Failure — never a bare apology; always the recovery path (spec §5.7)

    private func failureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Couldn't organize that just now", systemImage: "exclamationmark.triangle.fill")
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.amber)
            Text(message)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
            Text("Your words are saved. You can try again.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
            HStack {
                Button("Try again") { Task { await vm.save() } }
                    .buttonStyle(.borderedProminent)
                Button("Close") { finish() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Discard", role: .cancel) { finish() }
                .disabled(vm.isProcessing)
        }
        ToolbarItem(placement: .confirmationAction) {
            if case .editing = vm.phase {
                Button("Save") { Task { await vm.save() } }
                    .disabled(!vm.canSave)
            }
        }
    }

    private func finish() {
        vm.reset()
        capture.endCapture()
        dismiss()
    }
}

#Preview {
    CaptureView()
        .environment(CaptureCoordinator.shared)
}
