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
                // If the mic can't come up at all, fall through to the keyboard rather than
                // leaving the Action Button — the app's primary entry point — on a dead screen.
                if capture.consumeAutoListen() {
                    Task {
                        if await vm.beginAutoListen() == false { fieldFocused = true }
                    }
                } else {
                    fieldFocused = true
                }
            }
            // A mic that dies mid-session (recognizer error arriving after a clean start) has
            // no other way to reach the view — `beginAutoListen`'s return value only covers a
            // mic that never came up at all. This covers the rest: every voice failure ends
            // with a usable, focused text field, never a dead mic screen.
            .onChange(of: vm.focusTextFieldRequest) { _, _ in fieldFocused = true }
            // The AI couldn't run. An alert, not a screen: the words are still in the field
            // underneath, so dismissing puts the user back on their own sentence with the
            // keyboard up, one tap from sending it again.
            .alert("Couldn't sort this capture", isPresented: showingUnavailable) {
                Button("OK", role: .cancel) { fieldFocused = true }
            } message: {
                Text(vm.unavailableMessage ?? "")
            }
        }
    }

    /// Bridges the optional diagnosis to the `Bool` an alert wants; dismissing clears it.
    private var showingUnavailable: Binding<Bool> {
        Binding(
            get: { vm.unavailableMessage != nil },
            set: { shown in if !shown { vm.unavailableMessage = nil } }
        )
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What's on your mind?")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(Color.Offload.text)

            // A mic that wouldn't start says so here, without taking the editor away.
            if let banner = vm.errorBanner {
                Label(banner, systemImage: "mic.slash.fill")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.Offload.amber.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onTapGesture { vm.errorBanner = nil }
                    .accessibilityHint("Tap to dismiss")
            }

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
        .animation(Motion.standard, value: vm.errorBanner)
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
        // Everything said was already on the list. That's a success, and saying "Added 0 tasks"
        // would read as a failure of the capture rather than the point of having a list.
        if added == 0, !vm.alreadyOnList.isEmpty { return "Already got it" }
        return added == 1 ? "Added 1 task" : "Added \(added) tasks"
    }

    private func successView(added: Int, titles: [String], project: String?, similar: [String]) -> some View {
        VStack(spacing: 16) {
            Group {
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
                // The post-capture "file this under a project?" offer — an offer, not an
                // interrogation, since the capture already succeeded either way.
                if let suggestion = vm.suggestedProjectTitle {
                    projectOfferCard(title: suggestion)
                } else if let confirmed = vm.assignedProjectConfirmation {
                    projectAssignedConfirmation(title: confirmed)
                } else if let merged = vm.mergedProjectTitle {
                    projectMergedCard(title: merged)
                }
            }
            // Said again, already there. Deliberately styled as a result rather than a warning:
            // nothing went wrong, and the app catching a restatement is the feature working.
            if !vm.alreadyOnList.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(vm.alreadyOnList, id: \.self) { title in
                        Label("Already on your list: \(title)", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.Offload.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .animation(Motion.standard, value: vm.suggestedProjectTitle)
        .animation(Motion.standard, value: vm.assignedProjectConfirmation)
        .animation(Motion.standard, value: vm.mergedProjectTitle)
        // Auto-dismiss timing scales with how much there is to read; stay longer on warnings.
        // With refinement chips, the project offer, OR an automatic project merge present we
        // DON'T auto-dismiss — each one needs a tap the user can only give if the sheet is still
        // there, and an undo that vanishes on a timer is no undo at all. Answering any of them
        // lets the timer resume.
        .task(id: "\(vm.chips.count)-\(vm.suggestedProjectTitle ?? "")-\(vm.mergedProjectTitle ?? "")") {
            guard !vm.hasChips, vm.suggestedProjectTitle == nil, vm.mergedProjectTitle == nil else { return }
            let seconds = min(5.0, 1.6 + Double(titles.count) * 0.5 + Double(similar.count) * 1.0)
            try? await Task.sleep(for: .seconds(seconds))
            finish()
        }
    }

    /// A confident name match that already happened — "you said jury three, these went into Jury
    /// 3." A statement rather than a question, because asking about every obvious match would put
    /// a tap on most captures; the undo is what keeps it honest when the match is wrong.
    private func projectMergedCard(title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.Offload.indigo)
            Text("Filed under “\(title)”")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                Task { await vm.undoProjectMerge() }
            } label: {
                Text("Undo")
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.Offload.surface, in: .capsule)
                    .foregroundStyle(Color.Offload.indigo)
                    .overlay(Capsule().stroke(Color.Offload.divider, lineWidth: 1))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Undo filing these under \(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.Offload.indigo.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The post-capture "file this under a project?" offer (spec: captures naming real projects
    /// weren't landing under them). Same visual family as `chipRow`: a muted eyebrow label, then
    /// tappable capsules — a suggestion to weigh, not a decision the app is blocking on.
    private func projectOfferCard(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sounds like a project", systemImage: "folder.badge.plus")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(Color.Offload.muted)
            Text("File this under “\(title)”?")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
            HStack(spacing: 8) {
                Button {
                    Task { await vm.acceptSuggestedProject() }
                } label: {
                    Text("File it there")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.Offload.indigo, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("File this under \(title)")

                Button {
                    vm.declineSuggestedProject()
                } label: {
                    Text("Not now")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.Offload.surface, in: .capsule)
                        .foregroundStyle(Color.Offload.muted)
                        .overlay(Capsule().stroke(Color.Offload.divider, lineWidth: 1))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Don't file this under \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.Offload.indigo.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Brief, non-blocking confirmation once the offer above is accepted.
    private func projectAssignedConfirmation(title: String) -> some View {
        Label("Filed under “\(title)”", systemImage: "checkmark.circle.fill")
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(Color.Offload.teal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .transition(.opacity)
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
                // Gated on `canSave`: with nothing typed, `save()` returns immediately and the
                // button was a silent no-op on a screen with no other way forward.
                Button("Try again") { Task { await vm.save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canSave)
                // The way back to the editor, keeping whatever text you had. Without this, the
                // only exit from here was closing the sheet entirely.
                Button("Back to typing") { vm.backToEditing() }
                    .buttonStyle(.bordered)
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
