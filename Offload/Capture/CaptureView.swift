import SwiftUI

/// The capture screen (spec §5.5). Text-first: you can always type. Voice is added as an
/// additional mode in increment 4b. Save runs the on-device extraction pipeline and
/// reports how many tasks were added; failures keep your words and offer a retry.
struct CaptureView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CaptureViewModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .editing, .processing:
                    editor
                case let .done(added, titles, project):
                    successView(added: added, titles: titles, project: project)
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
            .onAppear { fieldFocused = true }
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What's on your mind?")
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)

            TextField("Speak or type a passing thought…", text: $vm.text, axis: .vertical)
                .font(.Offload.body)
                .lineLimit(3...12)
                .focused($fieldFocused)
                .disabled(vm.isProcessing)
                .padding()
                .background(Color.Offload.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Offload.divider, lineWidth: 1))

            // Voice is an *additional* input — the text field above always works too.
            HStack(spacing: 12) {
                Button {
                    Task { await vm.toggleMic() }
                } label: {
                    Label(vm.isListening ? "Listening… tap to stop" : "Speak instead",
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
                Spacer()
            }

            if vm.isProcessing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Organizing…")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                }
            }
            Spacer()
        }
    }

    // MARK: Success

    private func successView(added: Int, titles: [String], project: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.Offload.teal)
            Text(added == 1 ? "Added 1 task" : "Added \(added) tasks")
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            if let project {
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
            Button("Done") { finish() }
                .font(.Offload.taskTitle)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Color.Offload.indigo, in: .capsule)
                .foregroundStyle(.white)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        // Auto-dismiss timing scales a little with how much there is to read.
        .task {
            let seconds = min(3.5, 1.6 + Double(titles.count) * 0.5)
            try? await Task.sleep(for: .seconds(seconds))
            finish()
        }
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
