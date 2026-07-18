import SwiftUI

/// The minimal capture screen (spec §5.5). In increment 1 this is a visual shell:
/// a big text field + a "listening" affordance. On-device transcription and the
/// Foundation Models extraction pipeline are wired in later increments; for now the
/// Save button just dismisses so we have a real, tappable flow to build onto.
struct CaptureView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("What's on your mind?")
                    .font(.Offload.section)
                    .foregroundStyle(Color.Offload.text)

                TextField(
                    "Speak or type a passing thought…",
                    text: $text,
                    axis: .vertical
                )
                .font(.Offload.body)
                .lineLimit(3...10)
                .focused($fieldFocused)
                .padding()
                .background(Color.Offload.surface, in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.Offload.divider, lineWidth: 1)
                )

                Spacer()
            }
            .padding()
            .background(Color.Offload.background)
            .navigationTitle("Quick Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .cancel) { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { finish() }        // extraction lands in a later increment
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    private func finish() {
        text = ""
        capture.endCapture()
        dismiss()
    }
}

#Preview {
    CaptureView()
        .environment(CaptureCoordinator.shared)
}
