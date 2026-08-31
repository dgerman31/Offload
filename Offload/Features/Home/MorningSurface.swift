import SwiftUI

/// **Morning — decide the day.**
///
/// One job: look at the shape of today and commit to it. So the screen is the day's shape and a
/// button, and deliberately nothing else — no habits, no groceries, no running list, no
/// suggestions. Those are all things you'd *do*, and doing hasn't started yet.
///
/// The list is read-only. Every tappable row here would be an invitation to start working before
/// the plan exists, which is exactly the failure this screen is meant to remove.
struct MorningSurface: View {
    let items: [DayItem]
    let now: Date
    /// The occasional one-question interview — see `LifeBriefInterview`. Usually nil, which is the
    /// point: it appears when the app has a genuinely useful question and not on a schedule.
    var question: LifeBriefQuestion?
    var onPlan: () -> Void
    var onCommit: () -> Void
    var onAnswerQuestion: (String) -> Void = { _ in }
    var onDismissQuestion: () -> Void = {}

    /// Enough to see the shape of the day without turning the screen into the Day tab. If there's
    /// more than this, the count in the subtitle already told you.
    private static let visibleRows = 7

    private var timed: [DayItem] { items.filter { $0.time != nil } }

    private var headline: String {
        if items.isEmpty { return "Nothing planned yet." }
        return items.count == 1 ? "One thing today." : "\(items.count) things today."
    }

    private var subtitle: String {
        if items.isEmpty {
            return "An open day. Decide what it's for before it decides for you."
        }
        guard let first = timed.first, let time = first.time else {
            return "Nothing's pinned to an hour — take them in whatever order suits."
        }
        return "First up at \(TimeFormat.time(time)) · \(first.title)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PhaseHeadline(
                    eyebrow: now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                    title: headline,
                    subtitle: subtitle,
                    tint: DayPhase.morning.tint
                )

                if !items.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(Self.visibleRows).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().opacity(0.4) }
                            PhaseListRow(
                                time: item.time.map(TimeFormat.time),
                                title: item.title,
                                symbol: item.isEvent ? "calendar" : "circle",
                                tint: item.isEvent ? Color.Offload.teal : Color.Offload.muted
                            )
                        }
                    }

                    if items.count > Self.visibleRows {
                        Text("+ \(items.count - Self.visibleRows) more")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
                }

                // Under the plan, never over it. The morning screen's job is the day; this is the
                // one moment the app has your attention for something reflective, and it earns its
                // place only by being rare.
                if let question {
                    LifeBriefQuestionCard(question: question,
                                          onAnswered: onAnswerQuestion,
                                          onDismissed: onDismissQuestion)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            PhaseActionBar {
                if items.isEmpty {
                    PhasePrimaryButton(title: "Plan the day", symbol: "wand.and.stars",
                                       tint: Color.Offload.indigo, action: onPlan)
                } else {
                    // Committing is the primary action once a plan exists: the point of the
                    // morning screen is to end, and it ends when you've said yes to something.
                    PhasePrimaryButton(title: "Start the day", symbol: "arrow.forward",
                                       tint: Color.Offload.indigo, action: onCommit)
                    PhaseSecondaryButton(title: "Rework the plan", symbol: "wand.and.stars", action: onPlan)
                }
            }
        }
    }
}
