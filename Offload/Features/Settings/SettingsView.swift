import SwiftUI

/// Settings — availability status, Action Button setup, privacy (spec §5.4 / §5.6).
/// The availability card is real in increment 1; other controls arrive with their
/// features (dedupe threshold, categories, weekly insights, correction history).
struct SettingsView: View {
    @Environment(ModelAvailability.self) private var availability
    @AppStorage(ExtractionService.deliberateModeKey) private var deliberateMode = false
    @AppStorage(CaptureService.dedupeThresholdKey) private var dedupeThreshold = 0.85
    @State private var statsStore = StatsStore()
    @State private var insight: String?
    @State private var generatingInsight = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your progress") {
                    progressRow
                }

                Section("On-device AI") {
                    availabilityCard
                }

                Section {
                    Toggle("Deliberate mode", isOn: $deliberateMode)
                } header: {
                    Text("Thinking")
                } footer: {
                    Text("Lets the AI reason a little longer before organizing — slower (~2×), but better at compound thoughts and tricky timing.")
                }

                Section {
                    if let insight {
                        Text(insight)
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.text)
                    }
                    Button {
                        generatingInsight = true
                        Task {
                            insight = await InsightsService.generateInsight()
                            generatingInsight = false
                        }
                    } label: {
                        HStack {
                            Label(insight == nil ? "Generate weekly insight" : "Regenerate",
                                  systemImage: "sparkles")
                            if generatingInsight { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(generatingInsight)
                } header: {
                    Text("Weekly insight")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Duplicate sensitivity")
                            Spacer()
                            Text(String(format: "%.2f", dedupeThreshold))
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                        }
                        Slider(value: $dedupeThreshold, in: 0.7...0.95, step: 0.01)
                    }
                    NavigationLink("Correction history") { CorrectionHistoryView() }
                } header: {
                    Text("Learning")
                } footer: {
                    Text("Higher sensitivity flags only near-identical tasks as duplicates; lower catches looser matches.")
                }

                Section("Action Button") {
                    Label {
                        Text("Settings → Action Button → Shortcut → **Offload · Quick Capture**")
                            .font(.Offload.body)
                    } icon: {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(Color.Offload.indigo)
                    }
                    Text("The Quick Capture shortcut is also available in Shortcuts and Siri.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                    Label {
                        Text("From the lock screen — no unlock needed: say **“Hey Siri, tell Offload”** and speak your thought.")
                            .font(.Offload.body)
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.Offload.teal)
                    }
                }

                Section("Privacy") {
                    Label("Everything stays on this iPhone by default.",
                          systemImage: "lock.fill")
                        .foregroundStyle(Color.Offload.text)
                }
            }
            .navigationTitle("Settings")
            .task { await statsStore.observe() }
        }
    }

    private var progressRow: some View {
        let s = statsStore.stats
        return HStack(spacing: 0) {
            statTile("\(s.currentStreakDays)", "day streak", "flame.fill", Color.Offload.amber)
            Divider()
            statTile("\(s.completedToday)", "today", "checkmark.circle.fill", Color.Offload.green)
            Divider()
            statTile("\(s.completedThisWeek)", "this week", "calendar", Color.Offload.teal)
            Divider()
            statTile("\(s.openCount)", "open", "tray.fill", Color.Offload.indigo)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func statTile(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.system(.title3, design: .rounded)).fontWeight(.bold)
                .foregroundStyle(Color.Offload.text)
            Text(label).font(.caption).foregroundStyle(Color.Offload.muted)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: availability.state.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(availability.state.isAvailable ? Color.Offload.teal : Color.Offload.amber)
                Text(availability.headline)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
            }
            if let fix = availability.fixAction {
                Text(fix)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView().environment(ModelAvailability())
}
