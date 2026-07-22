import SwiftUI

/// The two bookends of a day.
///
/// **Morning brief** frames what's ahead before it starts. **Evening shutdown** is the more
/// important one: review what actually closed, decide honestly about what didn't, and empty
/// anything still rattling around — so the day ends in the app rather than in your head at 1am.
/// That closing ritual is the whole cognitive-offload promise, done deliberately once a day.
struct RitualView: View {
    enum Mode: String, Identifiable {
        case morning, evening

        var id: String { rawValue }
        var title: String { self == .morning ? "Morning brief" : "Close the day" }
        var accentColors: [Color] {
            self == .morning
                ? [Color(hex: 0x3B4CB8), Color(hex: 0x8A6FE0)]
                : [Color(hex: 0x1B1F45), Color(hex: 0x6A3F9E)]
        }
    }

    let mode: Mode
    let tasks: [TaskItem]
    let events: [CalendarEvent]
    var onPlanDay: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var brainDump = ""
    @State private var savingDump = false
    @State private var dumpSaved = false
    @State private var appeared = false
    @State private var now = Date()

    private var calendar: Calendar { .current }

    private var completedToday: [TaskItem] {
        tasks.filter { task in
            guard task.status == "completed", !task.deleted,
                  let done = DueDate.parse(task.completedAt) else { return false }
            return calendar.isDate(done, inSameDayAs: now)
        }
    }

    private var stillOpen: [TaskItem] {
        tasks.filter { task in
            guard task.status != "completed", !task.deleted,
                  let due = DueDate.parse(task.dueDate) else { return false }
            return due <= now || calendar.isDate(due, inSameDayAs: now)
        }
        .sorted { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
    }

    private var todayAhead: [DayItem] {
        DayTimeline.items(tasks: tasks, events: events, on: now)
    }

    private var load: MentalLoad { MentalLoad.compute(tasks: tasks, now: now) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero.appearIn(0, when: appeared)

                    if mode == .morning {
                        morningBody
                    } else {
                        eveningBody
                    }
                }
                .padding(18)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { finishBar }
            .task { withAnimation(Motion.settle) { appeared = true } }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DayDashboard.greeting(for: now).uppercased())
                .font(.caption).fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.7))
            Text(heroHeadline)
                .font(.system(.title, design: .rounded).weight(.bold))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(heroSubhead)
                .font(.Offload.body)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: mode.accentColors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 24, style: .continuous)
        )
        .elevated(.high)
    }

    private var heroHeadline: String {
        switch mode {
        case .morning:
            let count = todayAhead.count
            if count == 0 { return "A clear day" }
            return "\(count) thing\(count == 1 ? "" : "s") ahead"
        case .evening:
            let done = completedToday.count
            if done == 0 { return "Let's close up" }
            return "You closed \(done) loop\(done == 1 ? "" : "s")"
        }
    }

    private var heroSubhead: String {
        switch mode {
        case .morning:
            return todayAhead.isEmpty
                ? "Nothing scheduled. Take it as it comes."
                : "Here's the shape of it. Nothing else needs holding onto."
        case .evening:
            return stillOpen.isEmpty
                ? "Nothing left hanging. Put it down for the night."
                : "Decide what to do with what's left, then put the day down."
        }
    }

    // MARK: Morning

    @ViewBuilder
    private var morningBody: some View {
        if !todayAhead.isEmpty {
            section("Your day", icon: "clock.fill", tint: Color.Offload.teal, index: 1) {
                VStack(spacing: 0) {
                    ForEach(Array(todayAhead.enumerated()), id: \.element.id) { index, item in
                        TimelineRow(
                            accent: itemAccent(item),
                            isFirst: index == 0,
                            isLast: index == todayAhead.count - 1,
                            isPast: (item.time ?? .distantFuture) < now
                        ) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title)
                                    .font(.Offload.taskTitle)
                                    .foregroundStyle(Color.Offload.text)
                                Spacer(minLength: 8)
                                if let time = item.time {
                                    Text(CalendarView.time(time))
                                        .font(.Offload.data)
                                        .foregroundStyle(Color.Offload.muted)
                                        .lineLimit(1).fixedSize()
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }

        section("Mental load", icon: load.band.symbol, tint: Color.Offload.indigo, index: 2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(load.headline)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text(load.advice)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Evening

    @ViewBuilder
    private var eveningBody: some View {
        if !completedToday.isEmpty {
            section("Done today", icon: "checkmark.circle.fill", tint: Color.Offload.green, index: 1) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(completedToday) { task in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.Offload.green)
                                .font(.caption)
                            Text(task.title)
                                .font(.Offload.body)
                                .foregroundStyle(Color.Offload.muted)
                                .strikethrough(color: Color.Offload.muted)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }

        if !stillOpen.isEmpty {
            section("Still open", icon: "arrow.turn.down.right", tint: Color.Offload.amber, index: 2) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Move these to tomorrow, or leave them and decide in the morning.")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                    ForEach(stillOpen) { task in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.Offload.accent(for: task.category))
                                .frame(width: 6, height: 6)
                            Text(task.title)
                                .font(.Offload.body)
                                .foregroundStyle(Color.Offload.text)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button {
                                Task { await TaskActions.snooze(task, .tomorrow) }
                                Haptics.light()
                            } label: {
                                Text("Tomorrow")
                                    .font(.caption).fontWeight(.semibold)
                                    .lineLimit(1).fixedSize()
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                                    .foregroundStyle(Color.Offload.indigo)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }
            }
        }

        section("Anything still on your mind?", icon: "brain.head.profile", tint: Color.Offload.indigo, index: 3) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Empty it here and it'll be organized for you. Nothing needs carrying overnight.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                TextField("Type whatever's lingering…", text: $brainDump, axis: .vertical)
                    .font(.Offload.body)
                    .lineLimit(3...8)
                    .padding(12)
                    .background(Color.Offload.background, in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.Offload.divider, lineWidth: 1)
                    )
                    .disabled(savingDump)

                if dumpSaved {
                    Label("Captured — it'll be organized in a moment.", systemImage: "checkmark.circle.fill")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.green)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Chrome

    private func itemAccent(_ item: DayItem) -> Color {
        switch item {
        case let .event(event): return event.colorHex.map { Color(hex: $0) } ?? Color.Offload.teal
        case let .task(task):   return Color.Offload.accent(for: task.category)
        }
    }

    private func section<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        index: Int,
        @ViewBuilder content: () -> Content
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
        .appearIn(index, when: appeared)
    }

    /// "Day closed"/"Capture & close" read naturally for the evening; a morning brief shown
    /// without a "Plan my day" CTA (e.g. right after a schedule's already been submitted) just
    /// needs a plain acknowledgment instead.
    private var finishLabel: String {
        let hasDump = !brainDump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if mode == .morning { return "Got it" }
        return hasDump ? "Capture & close" : "Day closed"
    }

    private var finishBar: some View {
        VStack(spacing: 10) {
            if mode == .morning, onPlanDay != nil {
                Button {
                    dismiss()
                    onPlanDay?()
                } label: {
                    Label("Plan my day", systemImage: "wand.and.stars")
                        .font(.Offload.taskTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.Offload.indigo, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
            } else {
                Button {
                    Task { await finishEvening() }
                } label: {
                    HStack {
                        if savingDump { ProgressView().tint(.white) }
                        Text(finishLabel)
                            .font(.Offload.taskTitle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
                .disabled(savingDump)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    /// Run the brain dump through the normal capture pipeline so it gets organized like any
    /// other thought, then close. A failure still closes the day — the words are persisted by
    /// the pipeline before extraction is attempted, so nothing is lost either way.
    private func finishEvening() async {
        let text = brainDump.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Haptics.success()
            dismiss()
            return
        }
        savingDump = true
        _ = try? await CaptureService().process(rawInput: text, inputType: "text")
        savingDump = false
        withAnimation(Motion.standard) { dumpSaved = true }
        Haptics.success()
        try? await Task.sleep(for: .seconds(0.6))
        dismiss()
    }
}
