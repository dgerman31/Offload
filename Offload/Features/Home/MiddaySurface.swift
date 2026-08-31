import SwiftUI

/// **Now — do the thing.**
///
/// The most severe of the four screens, and the one the whole idea rests on. One task, set at four
/// times the size of anything else in the app, with everything that could possibly be compared
/// against it removed. No list, no counts, no progress ring, no "5 remaining" — because the moment
/// a second task is visible the screen's question changes from *do this* to *which of these*, and
/// that question is what the morning screen already answered.
///
/// The next thing is shown, once, as a single dimmed line at the bottom. It's there so the screen
/// doesn't feel like a dead end, and it's deliberately not tappable.
struct MiddaySurface: View {
    let task: TaskItem?
    let next: DayItem?
    var onFocus: (TaskItem) -> Void
    var onDone: (TaskItem) -> Void
    var onPickAnother: () -> Void
    var onCapture: () -> Void

    private func detail(_ task: TaskItem) -> String? {
        var parts: [String] = []
        if let minutes = task.effortMinutes { parts.append("about \(minutes) min") }
        if task.hasSpecificTime, let due = DueDate.parse(task.dueDate) {
            parts.append("planned for \(TimeFormat.time(due))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if let task {
                working(task)
            } else {
                clear
            }
        }
    }

    private func working(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 12)

            PhaseHeadline(
                eyebrow: "Now",
                title: task.title,
                subtitle: detail(task),
                tint: DayPhase.midday.tint
            )

            Spacer(minLength: 24)

            if let next {
                HStack(spacing: 8) {
                    Text("Then")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted.opacity(0.7))
                    Text(next.title)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 4)
                // Not a control, and it shouldn't read as one — it's the horizon, not a
                // destination.
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .safeAreaInset(edge: .bottom) {
            PhaseActionBar {
                PhasePrimaryButton(title: "Start focus", symbol: "timer",
                                   tint: Color.Offload.indigo) { onFocus(task) }
                HStack(spacing: 8) {
                    PhaseSecondaryButton(title: "Mark done", symbol: "checkmark") { onDone(task) }
                    PhaseSecondaryButton(title: "Something else", symbol: "arrow.triangle.2.circlepath",
                                         action: onPickAnother)
                }
            }
        }
        // Keyed to the task, so swapping what you're working on cross-fades rather than having one
        // title mutate into another mid-sentence.
        .id(task.id)
        .transition(.opacity)
    }

    /// Nothing left — which for this app is the goal, not an empty state. `ContentUnavailableView`
    /// is the system's own answer to "this screen has nothing on it", so it's what's used.
    private var clear: some View {
        ContentUnavailableView {
            Label("Nothing needs you", systemImage: "checkmark.circle")
        } description: {
            Text("Everything you planned for today is done or moved. Enjoy it — or offload whatever's turned up since.")
        } actions: {
            Button("Capture a thought", systemImage: "mic.fill", action: onCapture)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Color.Offload.indigo)
        }
    }
}
