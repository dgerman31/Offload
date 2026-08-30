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
    /// Today's Anki counts, pre-filled with yesterday's — they change daily but not wildly, and
    /// starting from the last numbers is faster than starting from zero.
    @State private var ankiDue = 0
    @State private var ankiNew = 0
    @State private var addingAnki = false
    /// Tasks created from inside this sheet. `tasks` is passed in by the parent and doesn't
    /// refresh while the sheet is open, so without this the Anki block would be written to the
    /// database and then be invisible to the very re-plan that's supposed to arrange the day
    /// around it.
    @State private var addedHere: [TaskItem] = []

    private var planningTasks: [TaskItem] { tasks + addedHere }

    private var ankiSettings: AnkiLoad.Settings { AnkiLoad.stored() }

    /// Whether today already has the Anki task, so the prompt asks once rather than every time
    /// the sheet is opened.
    private var ankiAlreadyPlanned: Bool {
        planningTasks.contains { task in
            task.title == AnkiLoad.taskTitle && task.status != "completed" && !task.deleted
                && (DueDate.parse(task.dueDate).map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false)
        }
    }

    /// Where the Anki block goes: the hour you actually woke, or now if you're already past it.
    /// Never in the past, because a block behind the current time isn't "first thing", it's
    /// already overdue.
    private var ankiStart: Date {
        let hour = WakeTracker.dayStartHour(now: Date(), fallback: dayStartHour)
        let calendar = Calendar.current
        let atWakeHour = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        let now = Date()
        let base = calendar.isDate(day, inSameDayAs: now) ? max(atWakeHour, now) : atWakeHour
        return DayPlanner.roundUpToQuarterHour(base)
    }

    private var kept: [DayPlanner.ScheduledTask] {
        plan.scheduled.filter { !dropped.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header.appearIn(0, when: appeared)

                    if !ankiAlreadyPlanned {
                        ankiPrompt.appearIn(1, when: appeared)
                    }

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
                                        .reorderable(id: item.id, onDrop: reorder)
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
                let last = AnkiLoad.lastCounts()
                ankiDue = last.due
                ankiNew = last.new
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
            tasks: planningTasks, events: events, on: day, now: Date(),
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

    /// Drag one proposed row before another and re-derive times from the new order — a plain
    /// deterministic recompute (`DayPlanner.plan(preferredOrder:)`, not `SmartPlanner`/AI again),
    /// since this is a manual tweak of a plan you're already looking at, not a fresh plan.
    /// Everything in `kept` already came from `DayPlanner.candidates`, which only ever returns
    /// flexible tasks, so there's no anchored item here that shouldn't be reorderable.
    private func reorder(draggedID: String, ontoID targetID: String) {
        var order = kept.map(\.id)
        guard let fromIndex = order.firstIndex(of: draggedID) else { return }
        order.remove(at: fromIndex)
        guard let toIndex = order.firstIndex(of: targetID) else { return }
        order.insert(draggedID, at: toIndex)

        let start = WakeTracker.dayStartHour(now: Date(), fallback: dayStartHour)
        let recomputed = DayPlanner.plan(
            tasks: planningTasks, events: events, on: day, now: Date(),
            dayStartHour: start, dayEndHour: dayEndHour,
            energyProfile: EnergyProfile(rawValue: energyRaw),
            preferredOrder: order,
            protected: ProtectedTime.stored()
        )
        withAnimation(Motion.standard) { plan = recomputed }
        Haptics.light()
    }

    // MARK: Anki

    /// The one number the app can't work out for itself.
    ///
    /// AnkiMobile exposes four URL schemes — `addnote`, `infoForAdding`, `search`, `sync` — and
    /// none of them returns a due count, so there is no way for Offload to read it. Nor is there
    /// a back door: AnkiWeb has no public API, AnkiConnect is desktop-only, and iOS sandboxing
    /// rules out reading another app's collection or its badge. Asking is the honest option, and
    /// it's two taps against a number that's already on the Anki screen you just came from.
    ///
    /// Everything downstream of the count *is* computed — see `AnkiLoad` for why the estimate is
    /// so much larger than cards × 15 seconds.
    private var ankiPrompt: some View {
        let minutes = AnkiLoad.minutes(due: ankiDue, new: ankiNew, settings: ankiSettings)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Anki first", systemImage: "rectangle.on.rectangle.angled")
                .font(.caption).fontWeight(.semibold)
                .tracking(0.6)
                .foregroundStyle(Color.Offload.accent(for: StudyCatalog.category))

            Text("How many cards today?")
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.text)

            HStack(spacing: 10) {
                CountStepper(label: "Due", value: $ankiDue, step: 10)
                CountStepper(label: "New", value: $ankiNew, step: 5)
            }

            if minutes > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AnkiLoad.durationLabel(minutes))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.Offload.text)
                    // The arithmetic, said out loud. An estimate this much larger than
                    // "cards × 15s" looks wrong until you can see where it came from.
                    Text(AnkiLoad.explanation(due: ankiDue, new: ankiNew, settings: ankiSettings))
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await addAnki() }
            } label: {
                HStack {
                    Label(minutes > 0 ? "Add it first, at \(TimeFormat.time(ankiStart))" : "Nothing due today",
                          systemImage: minutes > 0 ? "arrow.up.to.line" : "checkmark")
                        .font(.Offload.body).fontWeight(.semibold)
                    if addingAnki { Spacer(); ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(minutes > 0 ? Color.Offload.indigo : Color.Offload.surface,
                            in: .capsule)
                .foregroundStyle(minutes > 0 ? .white : Color.Offload.muted)
            }
            .buttonStyle(.pressable)
            .disabled(minutes == 0 || addingAnki)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.accent(for: StudyCatalog.category).opacity(0.10),
                    in: .rect(cornerRadius: 16, style: .continuous))
    }

    /// Create the Anki block, then re-plan so the rest of the day arranges itself around it.
    /// The task is pinned (`AnkiLoad.makeTask`), which is what makes "first" stick — a soft time
    /// would make it just another candidate the planner is free to reorder.
    private func addAnki() async {
        let minutes = AnkiLoad.minutes(due: ankiDue, new: ankiNew, settings: ankiSettings)
        guard minutes > 0 else { return }
        addingAnki = true
        AnkiLoad.rememberCounts(due: ankiDue, new: ankiNew)
        let task = AnkiLoad.makeTask(due: ankiDue, new: ankiNew, at: ankiStart, settings: ankiSettings)
        await TaskActions.create(task)
        addedHere.append(task)
        addingAnki = false
        Haptics.success()
        await recompute()
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
                        .foregroundStyle(Color.Offload.indigoText)
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
                        .foregroundStyle(Color.Offload.indigoText)
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
                    Text("\(TimeFormat.time(item.start)) – \(TimeFormat.time(item.end))")
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
                    .font(.system(.caption2, weight: .bold))
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

/// A count you can nudge or just type.
///
/// The steppers are right when the number is close — "about forty due" is two taps. They're the
/// wrong tool for 217, which is why the number itself is the field. It commits per keystroke
/// rather than on blur, so the time estimate above moves as you type.
private struct CountStepper: View {
    let label: String
    @Binding var value: Int
    var step: Int
    @FocusState private var editing: Bool

    /// Digits only, and capped at four — filtered rather than validated, because a number pad can
    /// still deliver a paste, and no day's card count needs five digits.
    private var text: Binding<String> {
        Binding(
            get: { String(value) },
            set: { value = Int($0.filter(\.isNumber).prefix(4)) ?? 0 }
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(.caption2, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Color.Offload.muted)
            HStack(spacing: 0) {
                stepButton("minus", enabled: value > 0) { value = max(0, value - step) }
                TextField("0", text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .focused($editing)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.Offload.text)
                    .frame(minWidth: 52)
                stepButton("plus", enabled: true) { value += step }
            }
            .padding(.vertical, 4)
            .background(editing ? Color.Offload.indigo.opacity(0.14) : Color.Offload.surface,
                        in: .capsule)
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.standard, value: editing)
        .toolbar {
            // A number pad has no return key, so without this there's no way back out. Attached
            // only while this field is focused, so the two steppers can't each contribute one.
            if editing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action(); Haptics.light()
        } label: {
            Image(systemName: symbol)
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(enabled ? Color.Offload.indigoText : Color.Offload.muted.opacity(0.4))
                .frame(width: 36, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
