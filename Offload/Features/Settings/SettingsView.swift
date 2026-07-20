import SwiftUI

/// Settings — availability status, Action Button setup, privacy (spec §5.4 / §5.6).
/// The availability card is real in increment 1; other controls arrive with their
/// features (dedupe threshold, categories, weekly insights, correction history).
struct SettingsView: View {
    @Environment(ModelAvailability.self) private var availability
    @AppStorage(ExtractionService.deliberateModeKey) private var deliberateMode = false
    @AppStorage(CaptureService.dedupeThresholdKey) private var dedupeThreshold = 0.85
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(NotificationService.remindersEnabledKey) private var remindersEnabled = false
    @AppStorage(NotificationService.briefEnabledKey) private var briefEnabled = false
    @AppStorage(NotificationService.briefHourKey) private var briefHour = NotificationService.defaultBriefHour
    @AppStorage(NotificationService.reviewEnabledKey) private var reviewEnabled = false
    @AppStorage(NotificationService.reviewHourKey) private var reviewHour = NotificationService.defaultReviewHour
    @State private var notificationsDenied = false

    /// "8 AM" / "9 PM" for the reminder-time pickers.
    static func hourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(suffix)"
    }
    @State private var statsStore = StatsStore()
    @State private var insight: String?
    @State private var generatingInsight = false
    @State private var confirmingErase = false
    @State private var erasing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your progress") {
                    progressRow
                }

                Section {
                    Picker("Appearance", selection: $themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Label(theme.label, systemImage: theme.icon).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: themeRaw) { _, _ in Haptics.light() }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Automatic follows your iPhone's light/dark setting.")
                }

                Section("On-device AI") {
                    availabilityCard
                }

                Section {
                    Toggle("Remind me when tasks are due", isOn: $remindersEnabled)
                    Toggle("Morning brief", isOn: $briefEnabled)
                    if briefEnabled {
                        Picker("Brief at", selection: $briefHour) {
                            ForEach(5...11, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                        }
                    }
                    Toggle("Evening review", isOn: $reviewEnabled)
                    if reviewEnabled {
                        Picker("Review at", selection: $reviewHour) {
                            ForEach(18...23, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                        }
                    }
                    if notificationsDenied {
                        Label("Notifications are off for Offload — turn them on in iOS Settings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.amber)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("All scheduled on-device — nothing is sent to a server. The morning brief tells you what the day holds before it starts.")
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

                Section {
                    Button(role: .destructive) {
                        confirmingErase = true
                    } label: {
                        HStack {
                            Label("Erase all tasks", systemImage: "trash.fill")
                            if erasing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(erasing)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Permanently deletes every task, project, and capture on this iPhone. This can't be undone.")
                }
            }
            .navigationTitle("Settings")
            .task { await statsStore.observe() }
            .task { notificationsDenied = !(await NotificationService.shared.isAuthorized) && anyNotificationOn }
            // Turning any reminder on is the natural moment to ask for permission; changing a
            // time reschedules immediately so the UI never lies about when you'll be nudged.
            .onChange(of: remindersEnabled) { _, on in Task { await applyNotificationSettings(requesting: on) } }
            .onChange(of: briefEnabled) { _, on in Task { await applyNotificationSettings(requesting: on) } }
            .onChange(of: reviewEnabled) { _, on in Task { await applyNotificationSettings(requesting: on) } }
            .onChange(of: briefHour) { _, _ in Task { await applyNotificationSettings(requesting: false) } }
            .onChange(of: reviewHour) { _, _ in Task { await applyNotificationSettings(requesting: false) } }
            // Destructive and irreversible — always confirm first (spec §5.7).
            .confirmationDialog("Erase all tasks?", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) {
                    erasing = true
                    Task {
                        try? await AppDatabase.shared.eraseAllData()
                        erasing = false
                        Haptics.success()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every task, project, and capture on this iPhone. It can't be undone.")
            }
        }
    }

    private var anyNotificationOn: Bool { remindersEnabled || briefEnabled || reviewEnabled }

    /// Ask for permission when a switch is first turned on, then push the whole schedule.
    private func applyNotificationSettings(requesting: Bool) async {
        let service = NotificationService.shared
        if requesting, !(await service.isAuthorized) {
            _ = await service.requestAuthorization()
        }
        let authorized = await service.isAuthorized
        notificationsDenied = anyNotificationOn && !authorized

        await service.scheduleEveningReview(enabled: reviewEnabled, hour: reviewHour)
        await service.scheduleDailyBrief(
            enabled: briefEnabled,
            hour: briefHour,
            summary: "Open Offload to see what today holds."
        )
        // Task reminders reconcile against live data, which the Home screen owns.
        await NotificationSync.shared.refresh(remindersEnabled: remindersEnabled)
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
