import SwiftUI

/// "Plan my day" — shows the proposed schedule before committing to it.
///
/// The plan is a *suggestion*: every row can be dropped with a tap, and nothing is written
/// until you accept. Applying it sets each task's due time, so the day then shows up on the
/// Home timeline and in your reminders like any other scheduled work.
struct DayPlanView: View {
    let tasks: [TaskItem]
    let events: [CalendarEvent]
    var day: Date = Date()
    var onApplied: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(DayPlanner.dayStartHourKey) private var dayStartHour = DayPlanner.defaultDayStartHour
    @AppStorage(DayPlanner.dayEndHourKey) private var dayEndHour = DayPlanner.defaultDayEndHour
    @AppStorage(EnergyProfile.storageKey) private var energyRaw = EnergyProfile.morning.rawValue

    @State private var plan = DayPlanner.Plan()
    @State private var rationale: String?
    @State private var usedAI = false
    @State private var planning = false
    @State private var dropped: Set<String> = []
    @State private var applying = false
    @State private var appeared = false

    private var kept: [DayPlanner.ScheduledTask] {
        plan.scheduled.filter { !dropped.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header.appearIn(0, when: appeared)

                    if plan.scheduled.isEmpty {
                        emptyState.appearIn(1, when: appeared)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(kept.enumerated()), id: \.element.id) { index, item in
                                TimelineRow(
                                    accent: Color.Offload.accent(for: item.task.category),
                                    isFirst: index == 0,
                                    isLast: index == kept.count - 1,
                                    isPast: false
                                ) {
                                    planRow(item)
                                }
                            }
                        }
                        .appearIn(1, when: appeared)
                    }

                    if !plan.unplaced.isEmpty {
                        unplacedSection.appearIn(2, when: appeared)
                    }
                }
                .padding(18)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Plan your day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { applyBar }
            .task {
                await recompute()
                withAnimation(Motion.settle) { appeared = true }
            }
            .onChange(of: dayStartHour) { _, _ in Task { await recompute() } }
            .onChange(of: dayEndHour) { _, _ in Task { await recompute() } }
            .onChange(of: energyRaw) { _, _ in Task { await recompute() } }
        }
    }

    private func recompute() async {
        // Start the day from when you actually woke, not a hardcoded hour — so an early or late
        // morning shifts the whole plan.
        let start = WakeTracker.dayStartHour(now: Date(), fallback: dayStartHour)
        planning = true
        let result = await SmartPlanner.plan(
            tasks: tasks, events: events, on: day, now: Date(),
            dayStartHour: start, dayEndHour: dayEndHour,
            energyProfile: EnergyProfile(rawValue: energyRaw)
        )
        withAnimation(Motion.standard) {
            plan = result.plan
            rationale = result.rationale
            usedAI = result.usedAI
            planning = false
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DayPlanner.summary(for: plan))
                .font(.system(.title3, design: .rounded).weight(.bold))
                .tracking(-0.3)
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Scheduled around your calendar, in the gaps you actually have free. Drop anything that doesn't belong.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .fixedSize(horizontal: false, vertical: true)

            // The AI's read on why the day is shaped this way — shown when Gemini ordered it.
            if let rationale, usedAI {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.Offload.indigo)
                    Text(rationale)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Offload.indigo.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            } else if planning {
                Label("Thinking about the best order…", systemImage: "sparkles")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }

            HStack(spacing: 8) {
                Label("\(DayPlanner.formatted(plan.freeMinutes)) free", systemImage: "clock")
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color.Offload.teal.opacity(0.14), in: .capsule)
                    .foregroundStyle(Color.Offload.teal)

                Menu {
                    Picker("Start", selection: $dayStartHour) {
                        ForEach(5...12, id: \.self) { Text(SettingsView.hourLabel($0)).tag($0) }
                    }
                    Picker("End", selection: $dayEndHour) {
                        ForEach(15...23, id: \.self) { Text(SettingsView.hourLabel($0)).tag($0) }
                    }
                    Picker("Best hours", selection: $energyRaw) {
                        ForEach(EnergyProfile.allCases) { profile in
                            Label(profile.label, systemImage: profile.icon).tag(profile.rawValue)
                        }
                    }
                } label: {
                    Label("\(SettingsView.hourLabel(dayStartHour))–\(SettingsView.hourLabel(dayEndHour))",
                          systemImage: "slider.horizontal.3")
                        .font(.caption).fontWeight(.medium)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.indigo)
                }
            }
        }
    }

    private func planRow(_ item: DayPlanner.ScheduledTask) -> some View {
        let tint = Color.Offload.accent(for: item.task.category)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.task.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                HStack(spacing: 8) {
                    Text("\(CalendarView.time(item.start)) – \(CalendarView.time(item.end))")
                        .font(.Offload.data)
                        .foregroundStyle(tint)
                    Text(DayPlanner.formatted(item.minutes))
                        .font(.caption)
                        .foregroundStyle(Color.Offload.muted)
                }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.standard) { _ = dropped.insert(item.id) }
                Haptics.light()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.Offload.muted)
                    .frame(width: 26, height: 26)
                    .background(Color.Offload.muted.opacity(0.12), in: .circle)
            }
            .buttonStyle(.pressable(scale: 0.85))
            .accessibilityLabel("Remove \(item.task.title) from the plan")
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.11), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var unplacedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Didn't fit today", systemImage: "tray.full")
                .font(.caption2).fontWeight(.bold)
                .tracking(0.9)
                .foregroundStyle(Color.Offload.amber)
            ForEach(plan.unplaced) { task in
                HStack(spacing: 10) {
                    Circle().fill(Color.Offload.accent(for: task.category)).frame(width: 6, height: 6)
                    Text(task.title)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.freeMinutes == 0 ? "Your day is already full" : "Nothing to schedule")
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.text)
            Text(plan.freeMinutes == 0
                 ? "Every hour in your window is taken by calendar events."
                 : "Capture a few things and they'll appear here ready to slot in.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .offloadCard()
    }

    private var applyBar: some View {
        Button {
            Task { await apply() }
        } label: {
            HStack {
                if applying { ProgressView().tint(.white) }
                Text(kept.isEmpty ? "Nothing to schedule" : "Schedule \(kept.count) task\(kept.count == 1 ? "" : "s")")
                    .font(.Offload.taskTitle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(kept.isEmpty ? Color.Offload.muted.opacity(0.3) : Color.Offload.indigo, in: .capsule)
            .foregroundStyle(.white)
        }
        .buttonStyle(.pressable)
        .disabled(kept.isEmpty || applying)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func apply() async {
        applying = true
        for item in kept {
            var updated = item.task
            updated.dueDate = DueDate.canonicalString(from: item.start)
            updated.dueDateConfidence = 1.0     // the user accepted this time
            updated.dueIsAllDay = false
            // The planner only *guessed* this time, so it stays soft — the timeline may reflow
            // it if the day slips. It's a suggestion, not a commitment you made.
            updated.pinned = false
            if updated.effortMinutes == nil { updated.effortMinutes = item.minutes }
            await TaskEditService.save(updated, original: item.task)
        }

        // Anything that still doesn't fit stays "today" — OverdueSweeper is now the single place
        // that decides when something has genuinely become yesterday's, the next time the app
        // opens on a new day. This screen doesn't need its own separate rollover rule anymore.
        applying = false
        Haptics.success()
        onApplied?()
        dismiss()
    }
}
