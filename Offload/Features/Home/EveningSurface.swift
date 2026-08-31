import SwiftUI

/// **Tonight — close the day out.**
///
/// The day's two numbers, and the one action that turns the leftovers into a decision instead of
/// a pile that gets decided for you at 6am. `EveningShutdownView` already does that work well;
/// this screen exists so it stops being a card you might scroll past and becomes the thing the app
/// is showing you.
///
/// What's deliberately absent: the running list, tomorrow's plan, and any suggestion about what to
/// do next. It's 8pm — the honest options are "finish this off" and "write down what's still
/// rattling around", so those are the only two offered.
struct EveningSurface: View {
    let summary: EveningShutdown.Summary
    let closed: Bool
    var onCloseOut: () -> Void
    var onWrite: () -> Void

    private var subtitle: String {
        if closed { return "The day's closed. Anything else can wait for the morning." }
        if summary.unfinished.isEmpty { return "Nothing left open. Worth marking the end of it anyway." }
        let count = summary.unfinished.count
        return "\(count) thing\(count == 1 ? "" : "s") still open. Decide where each one goes, and the day's done."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            PhaseHeadline(
                eyebrow: closed ? "Closed" : "Tonight",
                title: closed ? "That's the day." : EveningShutdown.headline(summary),
                subtitle: subtitle,
                tint: DayPhase.evening.tint
            )

            if !summary.completed.isEmpty || !summary.unfinished.isEmpty {
                HStack(alignment: .top, spacing: 40) {
                    tally(summary.completed.count, label: "done", tint: Color.Offload.green)
                    tally(summary.unfinished.count, label: "open", tint: Color.Offload.muted)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .safeAreaInset(edge: .bottom) {
            PhaseActionBar {
                if closed {
                    PhasePrimaryButton(title: "Write something down", symbol: "square.and.pencil",
                                       tint: Color.Offload.indigo, action: onWrite)
                } else {
                    PhasePrimaryButton(title: "Close out the day", symbol: "moon.stars.fill",
                                       tint: Color.Offload.indigo, action: onCloseOut)
                    PhaseSecondaryButton(title: "Write something down", symbol: "square.and.pencil",
                                         action: onWrite)
                }
            }
        }
    }

    /// One number, big, with its noun under it. Monospaced digits so the pair doesn't jitter when
    /// a count changes underneath.
    private func tally(_ count: Int, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.Offload.manrope(44, .bold, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(count)))
            Text(label)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
    }
}
