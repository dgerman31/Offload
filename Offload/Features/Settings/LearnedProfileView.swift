import SwiftUI
import GRDB

/// Everything the app has concluded about you, in one place, with a button to delete all of it.
///
/// This screen is the price of the rest of the learning being allowed to act on its own. An app
/// that quietly reserves 85 minutes for a task you said was 60 is either being helpful or being
/// broken, and from the outside those look identical. The difference is entirely whether you can
/// come here, see the sentence "your Work runs about 40% long, from 11 finished tasks", and
/// disagree with it.
///
/// Everything here is derived from your own history and never leaves the phone.
@MainActor
@Observable
final class LearnedProfileStore {
    private(set) var profile = LearnedProfile.stored()
    private(set) var outcomes = PlanOutcomes.Summary()
    private(set) var working = false

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func load() async {
        profile = LearnedProfile.stored()
        let tasks = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        outcomes = PlanOutcomes.summarize(tasks: tasks)
    }

    /// Recompute now rather than waiting for tonight — mostly so the screen can prove it's live.
    func recompute() async {
        working = true
        if let fresh = await LearningPass.run(db: db) { profile = fresh }
        await load()
        working = false
        Haptics.success()
    }

    func forget() async {
        LearnedProfile.forget()
        profile = LearnedProfile()
        Haptics.success()
    }
}

struct LearnedProfileView: View {
    @State private var store = LearnedProfileStore()
    @State private var confirmingForget = false

    private var profile: LearnedProfile { store.profile }

    var body: some View {
        List {
            if isEmpty {
                Section {
                    Text("Nothing yet. Offload learns from finished work and from timers you actually run — give it a couple of weeks of real use and this fills in.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                }
            }

            driftSection
            energySection
            outcomesSection
            priorsSection
            glossarySection

            Section {
                Button {
                    Task { await store.recompute() }
                } label: {
                    HStack {
                        Label("Recalculate now", systemImage: "arrow.clockwise")
                        if store.working { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.working)

                Button(role: .destructive) { confirmingForget = true } label: {
                    Label("Forget everything learned", systemImage: "trash")
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("What Offload has learned")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .confirmationDialog("Forget everything learned?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget it all", role: .destructive) {
                Task { await store.forget() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your tasks and history stay. Only the conclusions drawn from them are deleted — they'll build back up as you keep working.")
        }
    }

    private var isEmpty: Bool {
        profile.driftOverall == nil && profile.peakHours.isEmpty
            && profile.estimatePriors.isEmpty && profile.glossary.isEmpty
    }

    private var footer: String {
        guard let updated = profile.updatedAt else {
            return "Recalculated automatically, about once a day."
        }
        return "Last worked out \(TimeFormat.dayAndTime(updated)). Recalculated automatically, about once a day."
    }

    // MARK: How long things take

    @ViewBuilder
    private var driftSection: some View {
        if let overall = profile.driftOverall, profile.finishedTaskSample >= LearnedProfile.minimumDriftSample {
            Section {
                row(label: "Everything", value: percentLabel(overall))
                ForEach(profile.driftByCategory.sorted(by: { $0.key < $1.key }), id: \.key) { category, value in
                    row(label: category, value: percentLabel(value))
                }
            } header: {
                Text("How long work really takes")
            } footer: {
                Text("From \(profile.finishedTaskSample) finished tasks that had a timer running. Used to size the blocks the planner reserves, and to correct new estimates at capture.")
            }
        }
    }

    /// "about 40% longer than you think" — the figure, said in a way that means something.
    private func percentLabel(_ multiplier: Double) -> String {
        let percent = Int((abs(multiplier - 1) * 100).rounded())
        if percent < 10 { return "About right" }
        return multiplier > 1 ? "\(percent)% longer" : "\(percent)% quicker"
    }

    // MARK: When you work well

    @ViewBuilder
    private var energySection: some View {
        if !profile.peakHours.isEmpty {
            Section {
                hourChart
                if let line = EnergyCurve.describe(EnergyCurve.Curve(scores: profile.hourScores,
                                                                     peak: profile.peakHours,
                                                                     sample: profile.sessionSample)) {
                    Text(line)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.text)
                }
            } header: {
                Text("When you actually work")
            } footer: {
                Text("From \(profile.sessionSample) focus sessions — how long you stay with a sitting once you've started it, not how often you're scheduled. Demanding work gets planned into these hours.")
            }
        }
    }

    /// A bar per hour that has evidence. Peak hours are filled; the rest are outlines, so the
    /// shape of the day is readable at a glance rather than needing the numbers.
    private var hourChart: some View {
        let hours = profile.hourScores.keys.sorted()
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(hours, id: \.self) { hour in
                let score = profile.hourScores[hour] ?? 0
                let peak = profile.peakHours.contains(hour)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(peak ? Color.Offload.teal : Color.Offload.muted.opacity(0.28))
                        .frame(height: max(4, 46 * score))
                    Text(shortHour(hour))
                        .font(.system(.caption2, weight: peak ? .bold : .regular))
                        .foregroundStyle(peak ? Color.Offload.text : Color.Offload.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 66, alignment: .bottom)
        .padding(.vertical, 4)
        .accessibilityLabel("Your best hours are " + profile.peakHours.map(EnergyCurve.hourLabel).joined(separator: ", "))
    }

    private func shortHour(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12a"
        case 12: return "12p"
        case 1..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }

    // MARK: How plans go

    @ViewBuilder
    private var outcomesSection: some View {
        let lines = PlanOutcomes.observations(store.outcomes)
        if !lines.isEmpty {
            Section {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("How your plans go")
            } footer: {
                Text("Blocks that had a scheduled time in the last \(PlanOutcomes.windowDays) days. Work you moved to a later day isn't counted against you, so if anything this flatters you.")
            }
        }
    }

    // MARK: Learned estimates

    @ViewBuilder
    private var priorsSection: some View {
        if !profile.estimatePriors.isEmpty {
            Section {
                ForEach(profile.estimatePriors.prefix(12), id: \.key) { prior in
                    row(label: prior.label,
                        value: TimeFormat.duration(prior.medianMinutes),
                        detail: "\(prior.sample)×")
                }
            } header: {
                Text("What things take you")
            } footer: {
                Text("Work you've done at least \(EstimatePriors.minimumSample) times with a timer. New tasks that look like these start from your figure instead of the model's guess.")
            }
        }
    }

    // MARK: Vocabulary

    @ViewBuilder
    private var glossarySection: some View {
        if !profile.glossary.isEmpty {
            Section {
                FlowLayout(spacing: 6) {
                    ForEach(profile.glossary, id: \.self) { term in
                        Text(term)
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                            .foregroundStyle(Color.Offload.indigoText)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your words")
            } footer: {
                Text("Terms you use often enough that they're clearly yours. The AI is told to keep them exactly as you write them rather than tidying them into something it recognises.")
            }
        }
    }

    private func row(label: String, value: String, detail: String? = nil) -> some View {
        HStack {
            Text(label)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Text(value)
                .font(.Offload.data).fontWeight(.semibold)
                .foregroundStyle(Color.Offload.text)
        }
    }
}
