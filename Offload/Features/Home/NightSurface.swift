import SwiftUI

/// **Wind down — empty your head and put the phone down.**
///
/// The strictest screen in the app, and the only one that shows no task, no count and no progress
/// of any kind. That's not minimalism for its own sake: at 11pm a number telling you what you
/// didn't finish is information you can't act on, and the app handing it to you is how a day ends
/// in a scroll. There is nothing here to do except write, and one button that ends the session.
///
/// What you write goes through the normal capture pipeline, so a thought that turns out to be a
/// task becomes one in the morning — which is the entire point of writing it down instead of
/// keeping hold of it until 1am.
struct NightSurface: View {
    var onFinished: () -> Void

    @State private var text = ""
    @State private var saving = false
    @State private var saved = false
    @FocusState private var writing: Bool

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if saved { goodnight } else { writingScreen }
        }
        .animation(Motion.settle, value: saved)
    }

    private var writingScreen: some View {
        VStack(alignment: .leading, spacing: 24) {
            PhaseHeadline(
                eyebrow: "It's late",
                title: "Put it down.",
                subtitle: "Anything still going round — a worry, a half-thought, something you're afraid you'll forget. It gets sorted in the morning.",
                tint: DayPhase.night.tint
            )

            TextField("", text: $text, prompt: Text("Type it out…"), axis: .vertical)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .lineLimit(4...12)
                .focused($writing)
                .disabled(saving)
                .padding(16)
                .background(Color.Offload.surface, in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.Offload.hairline, lineWidth: 0.5)
                )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .toolbar {
            // Only while the keyboard is up. A vertical-axis field has no return key to submit
            // with, so without this there's no way back out on a screen with nothing else to tap.
            if writing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { writing = false }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            PhaseActionBar {
                PhasePrimaryButton(title: hasText ? "Put it down" : "Goodnight",
                                   symbol: hasText ? "arrow.down.circle.fill" : "moon.fill",
                                   tint: Color.Offload.indigo) {
                    Task { await save() }
                }
                .disabled(saving)
            }
        }
    }

    /// The end of the session. One word, no controls worth pressing — the screen's last job is to
    /// stop being interesting.
    private var goodnight: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(.largeTitle))
                .foregroundStyle(DayPhase.night.tint)
            Text("Goodnight.")
                .font(.Offload.manrope(30, .bold, relativeTo: .largeTitle))
                .foregroundStyle(Color.Offload.text)
            Text("It's written down. Nothing else needs you tonight.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .multilineTextAlignment(.center)
            Button("Something else came up") {
                withAnimation(Motion.standard) { saved = false }
            }
            .font(.Offload.body)
            .foregroundStyle(Color.Offload.muted.opacity(0.8))
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    @MainActor
    private func save() async {
        writing = false
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else {
            Haptics.success()
            withAnimation(Motion.settle) { saved = true }
            onFinished()
            return
        }
        saving = true
        // Fire-and-forget by design: extraction can take a few seconds and this screen's promise
        // is that you're finished the moment you tap. The capture row is written first either way,
        // so nothing is lost if the model is slow or unreachable.
        _ = try? await CaptureService().process(rawInput: entry, inputType: "text")
        saving = false
        text = ""
        Haptics.success()
        withAnimation(Motion.settle) { saved = true }
        onFinished()
    }
}
