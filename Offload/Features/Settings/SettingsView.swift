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
    @AppStorage(EnergyProfile.storageKey) private var energyRaw = EnergyProfile.morning.rawValue
    @AppStorage(DayPlanner.dayStartHourKey) private var dayStartHour = DayPlanner.defaultDayStartHour
    @AppStorage(DayPlanner.dayEndHourKey) private var dayEndHour = DayPlanner.defaultDayEndHour
    @AppStorage(FocusTimer.focusMinutesKey) private var focusMinutes = FocusTimer.defaultFocusMinutes
    @AppStorage(FocusTimer.shortBreakMinutesKey) private var shortBreakMinutes = FocusTimer.defaultShortBreakMinutes
    @AppStorage(FocusTimer.longBreakMinutesKey) private var longBreakMinutes = FocusTimer.defaultLongBreakMinutes
    @AppStorage(AnkiLoad.secondsPerAnswerKey) private var ankiSeconds = AnkiLoad.defaultSecondsPerAnswer
    @AppStorage(AnkiLoad.reviewAgainRateKey) private var ankiReviewAgain = AnkiLoad.defaultReviewAgainRate
    @AppStorage(AnkiLoad.newAgainRateKey) private var ankiNewAgain = AnkiLoad.defaultNewAgainRate
    @AppStorage(AnkiLoad.newStepsKey) private var ankiNewSteps = AnkiLoad.defaultNewSteps
    @State private var notificationsDenied = false

    /// A worked example at the current settings, so the difference from the old flat estimate is
    /// concrete rather than asserted.
    static func ankiExample() -> String {
        let settings = AnkiLoad.stored()
        let minutes = AnkiLoad.minutes(due: 150, new: 30, settings: settings)
        let flat = (180 * settings.secondsPerAnswer) / 60
        return "150 due + 30 new ≈ \(AnkiLoad.durationLabel(minutes)), where counting cards alone would say \(flat)m."
    }

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
    @State private var eraseFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your progress") {
                    progressRow
                    NavigationLink {
                        InsightsView()
                    } label: {
                        Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    NavigationLink {
                        JournalView()
                    } label: {
                        Label("Journal", systemImage: "book.closed.fill")
                    }
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

                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Intelligence")
                                Text(SecretStore.hasGeminiKey ? "Gemini connected" : "On-device only — add a key for more")
                                    .font(.Offload.data)
                                    .foregroundStyle(Color.Offload.muted)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                    }
                } header: {
                    Text("AI")
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
                    Picker("Day starts", selection: $dayStartHour) {
                        ForEach(5...12, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                    }
                    Picker("Day ends", selection: $dayEndHour) {
                        ForEach(15...23, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                    }
                    NavigationLink {
                        MyWeekView()
                    } label: {
                        Label("My week", systemImage: "calendar.badge.clock")
                    }
                } header: {
                    Text("Scheduling")
                } footer: {
                    Text("A capture or task with no specific time gets slotted into whatever's open before \(Self.hourLabel(dayEndHour)). Past that, it schedules into tomorrow instead of sitting unscheduled today. “My week” is where you reserve the hours it must leave alone.")
                }

                Section {
                    Picker("Seconds per answer", selection: $ankiSeconds) {
                        ForEach([8, 10, 12, 15, 18, 20, 25], id: \.self) { Text("\($0)s").tag($0) }
                    }
                    Picker("Again rate, reviews", selection: $ankiReviewAgain) {
                        ForEach([0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40], id: \.self) {
                            Text("\(Int($0 * 100))%").tag($0)
                        }
                    }
                    Picker("Again rate, new cards", selection: $ankiNewAgain) {
                        ForEach([0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50], id: \.self) {
                            Text("\(Int($0 * 100))%").tag($0)
                        }
                    }
                    Picker("Learning steps", selection: $ankiNewSteps) {
                        ForEach([1, 2, 3], id: \.self) { Text("\($0) in a row").tag($0) }
                    }
                } header: {
                    Text("Anki")
                } footer: {
                    Text("An estimate counts *answers*, not cards: a lapse sends a card back through its learning steps, so a new card needing 2 in a row at 30% again takes about 3.5 answers, not 2. \(Self.ankiExample()) Offload can't read your due count — AnkiMobile doesn't expose one — so Plan my day asks.")
                }

                Section {
                    Picker("Focus block", selection: $focusMinutes) {
                        ForEach([15, 20, 25, 30, 45, 50, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Picker("Break", selection: $shortBreakMinutes) {
                        ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Picker("Long break", selection: $longBreakMinutes) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                } header: {
                    Text("Focus timer")
                } footer: {
                    Text("A long break after every \(FocusTimer.blocksPerLongBreak) blocks. The timer keeps running when you leave the app or lock the phone, and shows on the Lock Screen — a block's length is how long you work in one sitting, not how long the whole task takes.")
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
                    NavigationLink {
                        LearnedProfileView()
                    } label: {
                        Label("What Offload has learned", systemImage: "brain")
                    }
                    NavigationLink("Correction history") { CorrectionHistoryView() }
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Categories", systemImage: "tag.fill")
                    }
                    NavigationLink {
                        RoutinesView()
                    } label: {
                        Label("Routines", systemImage: "repeat")
                    }
                    Picker(selection: $energyRaw) {
                        ForEach(EnergyProfile.allCases) { profile in
                            Label(profile.label, systemImage: profile.icon).tag(profile.rawValue)
                        }
                    } label: {
                        Label("Best hours", systemImage: "bolt.fill")
                    }
                    // Said plainly rather than left to be discovered: once there's enough focus
                    // history, this picker stops being what the planner uses. A setting that
                    // silently does nothing is worse than no setting.
                    if LearnedProfile.stored().learnedPeakHours != nil {
                        Text("Offload has measured your real hours and is using those instead. See “What Offload has learned”.")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
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
                            .foregroundStyle(Color.Offload.indigoText)
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
                    ExportDataButton()
                    Button(role: .destructive) {
                        confirmingErase = true
                    } label: {
                        HStack {
                            Label("Erase all tasks", systemImage: "trash.fill")
                            if erasing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(erasing)
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export writes one readable JSON file you own — no lock-in. Erase permanently deletes every task, project, and capture on this iPhone and can't be undone. Diagnostics shows what the app has been doing this launch, for when something didn't work and you want to know why.")
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
                        // The one irreversible action in the app used to be `try?` followed by an
                        // unconditional success haptic — so a failed erase felt exactly like a
                        // successful one, and the user walked away believing their data was gone.
                        // The delete runs in a single transaction, so a throw means nothing was
                        // deleted, which is what the failure alert can honestly say.
                        do {
                            try await AppDatabase.shared.eraseAllData()
                            Haptics.success()
                        } catch {
                            Log.database.error("erase all data failed: \(error.localizedDescription)")
                            Haptics.warning()
                            eraseFailed = true
                        }
                        erasing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every task, project, and capture on this iPhone. It can't be undone.")
            }
            .alert("Couldn't erase your data", isPresented: $eraseFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was deleted — the whole erase runs at once, so it either all happens or none of it does. Try again, and if it keeps failing, restart Offload.")
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
            statTile("\(s.openCount)", "open", "tray.fill", Color.Offload.indigoText)
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
