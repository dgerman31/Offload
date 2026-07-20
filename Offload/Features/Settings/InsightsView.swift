import SwiftUI

/// Insights — the data the app has been quietly collecting, finally made visible.
///
/// Streaks, completions, banked focus minutes, mental load and where your effort actually goes.
/// Framed as a mirror rather than a scoreboard: the point isn't to gamify, it's to notice
/// things like "every Thursday overloads" that you can act on.
struct InsightsView: View {
    @State private var store = TaskStore()
    @State private var statsStore = StatsStore()
    @State private var insight: String?
    @State private var generating = false
    @State private var appeared = false
    @AppStorage(FocusSession.totalMinutesKey) private var focusMinutes = 0
    @AppStorage(FocusSession.sessionCountKey) private var focusSessions = 0

    private var load: MentalLoad {
        MentalLoad.compute(tasks: store.allTasks, now: Date())
    }

    private var weekly: InsightsService.WeeklyStats {
        InsightsService.weeklyStats(tasks: store.allTasks, captures: [], now: Date())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statGrid.appearIn(0, when: appeared)
                loadCard.appearIn(1, when: appeared).scrollAppear()
                reviewCard.appearIn(2, when: appeared).scrollAppear()
                if !habitNotes.isEmpty {
                    habitsCard.appearIn(2, when: appeared).scrollAppear()
                }
                if !weekly.categoryMix.isEmpty {
                    categoryCard.appearIn(3, when: appeared).scrollAppear()
                }
                reflectionCard.appearIn(3, when: appeared).scrollAppear()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.Offload.background)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .task { await statsStore.observe() }
        .task { withAnimation(Motion.settle) { appeared = true } }
    }

    // MARK: Stats

    private var statGrid: some View {
        let s = statsStore.stats
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                         spacing: 12) {
            statTile("\(s.currentStreakDays)", "day streak", "flame.fill", Color.Offload.amber)
            statTile("\(s.completedThisWeek)", "done this week", "checkmark.circle.fill", Color.Offload.green)
            statTile(DayPlanner.formatted(focusMinutes), "focused", "timer", Color.Offload.teal)
            statTile("\(focusSessions)", "focus session\(focusSessions == 1 ? "" : "s")",
                     "brain.head.profile", Color.Offload.indigo)
        }
    }

    private func statTile(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13), in: .rect(cornerRadius: 10, style: .continuous))
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.Offload.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label)
                .font(.Offload.data)
                .foregroundStyle(Color.Offload.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .offloadCard(cornerRadius: 16)
    }

    // MARK: Mental load

    private var loadCard: some View {
        let l = load
        return card("Mental load", icon: l.band.symbol, tint: bandTint(l.band)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(bandTint(l.band).opacity(0.18), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: max(0.02, Double(l.score) / 100))
                            .stroke(bandTint(l.band), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(Motion.settle, value: l.score)
                        VStack(spacing: 0) {
                            Text("\(l.score)")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .foregroundStyle(Color.Offload.text)
                            Text(l.band.rawValue)
                                .font(.caption2)
                                .foregroundStyle(Color.Offload.muted)
                        }
                    }
                    .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(l.headline)
                            .font(.Offload.taskTitle)
                            .foregroundStyle(Color.Offload.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l.advice)
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    loadChip("\(l.overdue)", "overdue", Color.Offload.red)
                    loadChip("\(l.dueToday)", "today", Color.Offload.amber)
                    loadChip("\(l.unscheduled)", "loose", Color.Offload.muted)
                }
            }
        }
    }

    private func loadChip(_ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.bold)
            Text(label)
        }
        .font(.caption)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.13), in: .capsule)
        .foregroundStyle(tint)
    }

    private func bandTint(_ band: MentalLoad.Band) -> Color {
        switch band {
        case .clear: return Color.Offload.green
        case .light: return Color.Offload.teal
        case .full:  return Color.Offload.amber
        case .heavy: return Color.Offload.red
        }
    }

    // MARK: Habits

    private var habitNotes: [String] {
        HabitLearning.observations(HabitLearning.learn(from: store.allTasks, now: Date()))
    }

    /// Patterns derived from your own completion history — shown only once there's enough of
    /// it to mean something, so the app never claims to know you before it does.
    private var habitsCard: some View {
        card("How you work", icon: "waveform.path.ecg", tint: Color.Offload.teal) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(habitNotes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(Color.Offload.teal)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(note)
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Week review

    /// The slower failures a daily view can't see: the task snoozed four times, the thing
    /// that's sat undated for a month, the week where you took on more than you closed.
    private var reviewCard: some View {
        let findings = WeekReview.findings(tasks: store.allTasks, now: Date())
        return card("Your week", icon: "calendar.badge.clock", tint: Color.Offload.amber) {
            VStack(alignment: .leading, spacing: 12) {
                if findings.completed > 0 || findings.captured > 0 {
                    HStack(spacing: 8) {
                        loadChip("\(Int(findings.completionRate * 100))%", "finished", Color.Offload.green)
                        if findings.overdue > 0 {
                            loadChip("\(findings.overdue)", "overdue", Color.Offload.red)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(WeekReview.observations(findings), id: \.self) { line in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(Color.Offload.amber)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(line)
                                .font(.Offload.body)
                                .foregroundStyle(Color.Offload.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: Where effort goes

    private var categoryCard: some View {
        let mix = weekly.categoryMix
        let total = max(1, mix.reduce(0) { $0 + $1.count })
        return card("Where your week went", icon: "chart.pie.fill", tint: Color.Offload.teal) {
            VStack(alignment: .leading, spacing: 12) {
                // Single stacked bar — proportions read faster than a list of numbers.
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(mix, id: \.category) { entry in
                            Color.Offload.accent(for: entry.category)
                                .frame(width: max(4, geo.size.width * Double(entry.count) / Double(total)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)

                VStack(spacing: 6) {
                    ForEach(mix, id: \.category) { entry in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.Offload.accent(for: entry.category))
                                .frame(width: 7, height: 7)
                            Text(entry.category)
                                .font(.Offload.body)
                                .foregroundStyle(Color.Offload.text)
                            Spacer(minLength: 0)
                            Text("\(entry.count)")
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                        }
                    }
                }
            }
        }
    }

    // MARK: Model reflection

    private var reflectionCard: some View {
        card("This week", icon: "sparkles", tint: Color.Offload.indigo) {
            VStack(alignment: .leading, spacing: 12) {
                if let insight {
                    Text(insight)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Ask for a short reflection on how the week actually went, written on-device from your real numbers.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    generating = true
                    Task {
                        insight = await InsightsService.generateInsight()
                        generating = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if generating { ProgressView().controlSize(.small) }
                        Text(insight == nil ? "Write my reflection" : "Rewrite")
                            .font(.caption).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                    .foregroundStyle(Color.Offload.indigo)
                }
                .buttonStyle(.pressable)
                .disabled(generating)
            }
        }
    }

    private func card<Content: View>(
        _ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2).fontWeight(.bold)
                .tracking(0.9)
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }
}
