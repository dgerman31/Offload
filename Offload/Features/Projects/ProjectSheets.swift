import SwiftUI

/// Add one row of a known kind.
///
/// The kind is decided *before* the sheet opens — you tapped "+" on Ideas, so you're adding an
/// idea — which is the whole reason this is a separate sheet rather than the general add-task form.
/// A form that makes you pick a type from a menu every time is a form that gets used once.
struct QuickAddSheet: View {
    let kind: CaptureKind
    let projectTitle: String
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var writing: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Prompts written as the thing itself, not as a field label — "What could you try?" gets a
    /// different answer than "Title".
    private var prompt: String {
        switch kind {
        case .task, .commitment: return "What needs doing?"
        case .idea:              return "What could you try?"
        case .note:              return "What's worth keeping?"
        case .question:          return "What don't you know yet?"
        case .decision:          return "What did you decide?"
        case .waiting:           return "What are you waiting on, and from whom?"
        case .event:             return "What's the appointment?"
        case .reflection:        return "What's on your mind?"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(prompt)
                    .font(.Offload.manrope(20, .bold))
                    .foregroundStyle(Color.Offload.text)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("", text: $text, prompt: Text(placeholder), axis: .vertical)
                    .font(.Offload.body)
                    .lineLimit(3...8)
                    .focused($writing)
                    .padding(14)
                    .background(Color.Offload.surface, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.Offload.hairline, lineWidth: 0.5)
                    )

                if kind.keepsWording {
                    // Said out loud, because it's the difference people notice: this box is not a
                    // task field wearing a different label.
                    Label("Kept in your words. Never scheduled, never overdue.", systemImage: "quote.opening")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Offload.background)
            .navigationTitle("\(kind.label) · \(projectTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(trimmed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty)
                }
            }
            .task {
                // The sheet exists to catch one line; opening it with the keyboard down would add
                // a tap to every use.
                try? await Task.sleep(for: .milliseconds(180))
                writing = true
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case .task, .commitment: return "Email the PI about the dataset"
        case .idea:              return "Could run the whole thing off the topic list instead"
        case .note:              return "Ethics approval number is 2026-114"
        case .question:          return "Do we need consent forms for the retrospective arm?"
        case .decision:          return "Going with the retrospective design, not the survey"
        case .waiting:           return "Dr. Okafor — signed authorship form"
        case .event:             return "Committee meeting, Thursday 2pm"
        case .reflection:        return "How this is going"
        }
    }
}

/// A dated line in the project log.
struct ProjectUpdateSheet: View {
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var writing: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What changed?")
                    .font(.Offload.manrope(20, .bold))
                    .foregroundStyle(Color.Offload.text)
                TextField("", text: $text,
                          prompt: Text("Finally got the data pull working — the rest is just analysis"),
                          axis: .vertical)
                    .font(.Offload.body)
                    .lineLimit(3...8)
                    .focused($writing)
                    .padding(14)
                    .background(Color.Offload.surface, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.Offload.hairline, lineWidth: 0.5)
                    )
                Text("Kept with today's date, next to where the project was on the hill. This is what makes it possible to see later whether anything was actually moving.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Offload.background)
            .navigationTitle("Log an update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(trimmed); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(180))
                writing = true
            }
        }
    }
}

/// The project in the user's own words.
struct ProjectBriefSheet: View {
    let text: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var writing: Bool

    init(text: String, onSave: @escaping (String) -> Void) {
        self.text = text
        self.onSave = onSave
        _draft = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What is this project, and what does done look like?")
                    .font(.Offload.manrope(20, .bold))
                    .foregroundStyle(Color.Offload.text)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $draft,
                          prompt: Text("A retrospective chart review on post-op delirium. Done means a submitted abstract by March."),
                          axis: .vertical)
                    .font(.Offload.body)
                    .lineLimit(5...14)
                    .focused($writing)
                    .padding(14)
                    .background(Color.Offload.surface, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.Offload.hairline, lineWidth: 0.5)
                    )
                Text("Yours, not the app's. It's also the best single thing you can give the AI about this project — it reads it when filing anything you capture.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Offload.background)
            .navigationTitle("Brief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(180))
                writing = true
            }
        }
    }
}
