import SwiftUI

/// The bookend to "Plan my day": what today came to, and where the rest of it is going.
///
/// The sheet's whole job is to turn the unfinished pile into a decision you made rather than one
/// that gets made for you at 6am. Nothing is written until you close it out — the ticks and drops
/// you make in here are staged, so backing out costs nothing.
struct EveningShutdownView: View {
    let tasks: [TaskItem]
    var now: Date = Date()
    var store: TaskStore
    var onFinished: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// Staged decisions, applied together on close. Ids rather than tasks, so a row that changes
    /// underneath (a step ticked elsewhere) can't resurrect a stale copy.
    @State private var finishing: Set<String> = []
    @State private var dropping: Set<String> = []
    @State private var working = false
    @State private var appeared = false

    private var summary: EveningShutdown.Summary {
        EveningShutdown.summary(tasks: tasks, now: now)
    }

    private var rolling: [TaskItem] {
        summary.unfinished.filter { !finishing.contains($0.id) && !dropping.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.appearIn(0, when: appeared)

                    if !summary.completed.isEmpty {
                        section("DONE TODAY") {
                            ForEach(summary.completed) { task in
                                doneRow(task)
                            }
                        }
                        .appearIn(1, when: appeared)
                    }

                    if !summary.unfinished.isEmpty {
                        section("STILL OPEN") {
                            ForEach(summary.unfinished) { task in
                                openRow(task)
                            }
                        }
                        .appearIn(2, when: appeared)
                    }

                    if let first = summary.firstTomorrow {
                        tomorrowLine(first).appearIn(3, when: appeared)
                    }
                }
                .padding(18)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Close out the day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not yet") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { closeBar }
            .task { withAnimation(Motion.settle) { appeared = true } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EveningShutdown.headline(summary))
                .font(.Offload.manrope(22, .bold))
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)
            if !summary.unfinished.isEmpty {
                Text("Tick anything you actually did, drop what stopped mattering. The rest moves to tomorrow.")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.Offload.manrope(11, .heavy))
                .tracking(1)
                .foregroundStyle(Color.Offload.muted)
            VStack(spacing: 8) { rows() }
        }
    }

    private func doneRow(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.Offload.green)
            Text(task.title)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.surface, in: .rect(cornerRadius: 14, style: .continuous))
    }

    /// One unfinished task and the three things you can do with it: say it's done, drop it, or
    /// leave it alone and let it move. Leaving it alone is the default, which is why it needs no
    /// control of its own.
    private func openRow(_ task: TaskItem) -> some View {
        let isDone = finishing.contains(task.id)
        let isDropped = dropping.contains(task.id)
        return HStack(spacing: 10) {
            Button {
                toggle(task.id, in: $finishing, clearing: $dropping)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(.title3, weight: .medium))
                    .foregroundStyle(isDone ? Color.Offload.green : Color.Offload.muted.opacity(0.5))
                    .symbolEffect(.bounce, value: isDone)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.Offload.body)
                    .strikethrough(isDone || isDropped, color: Color.Offload.muted)
                    .foregroundStyle(isDone || isDropped ? Color.Offload.muted : Color.Offload.text)
                    .lineLimit(2)
                Text(fate(task, isDone: isDone, isDropped: isDropped))
                    .font(.Offload.data)
                    .foregroundStyle(isDropped ? Color.Offload.red : Color.Offload.muted)
            }
            Spacer(minLength: 0)

            Button {
                toggle(task.id, in: $dropping, clearing: $finishing)
            } label: {
                Image(systemName: isDropped ? "arrow.uturn.backward" : "xmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(Color.Offload.muted)
                    .frame(width: 30, height: 30)
                    .background(Color.Offload.background, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDropped ? "Keep \(task.title)" : "Drop \(task.title)")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.surface, in: .rect(cornerRadius: 14, style: .continuous))
        .animation(Motion.standard, value: isDone)
        .animation(Motion.standard, value: isDropped)
    }

    private func fate(_ task: TaskItem, isDone: Bool, isDropped: Bool) -> String {
        if isDone { return "Done" }
        if isDropped { return "Dropped" }
        let placement = EveningShutdown.tomorrowPlacement(for: task, now: now)
        return placement.isAllDay ? "Moves to tomorrow" : "Moves to tomorrow, \(TimeFormat.time(placement.dueDate))"
    }

    private func tomorrowLine(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sunrise.fill")
                .foregroundStyle(Color.Offload.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tomorrow starts with")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                Text(task.hasSpecificTime && DueDate.parse(task.dueDate) != nil
                     ? "\(task.title) · \(TimeFormat.time(DueDate.parse(task.dueDate) ?? now))"
                     : task.title)
                    .font(.Offload.body).fontWeight(.semibold)
                    .foregroundStyle(Color.Offload.text)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.surface, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var closeBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            Button {
                Task { await finish() }
            } label: {
                HStack {
                    Text(closeLabel)
                        .font(.Offload.body).fontWeight(.semibold)
                    if working { Spacer(); ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.Offload.indigo, in: .capsule)
                .foregroundStyle(.white)
            }
            .buttonStyle(.pressable)
            .disabled(working)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    private var closeLabel: String {
        if rolling.isEmpty { return "That's the day" }
        return rolling.count == 1 ? "Move 1 to tomorrow" : "Move \(rolling.count) to tomorrow"
    }

    private func toggle(_ id: String, in set: Binding<Set<String>>, clearing other: Binding<Set<String>>) {
        if set.wrappedValue.contains(id) {
            set.wrappedValue.remove(id)
        } else {
            set.wrappedValue.insert(id)
            other.wrappedValue.remove(id)      // the two decisions are mutually exclusive
        }
        Haptics.light()
    }

    @MainActor
    private func finish() async {
        working = true
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps on a duplicate
        // id, and a crash on the way out of a day is a poor trade for a defensive detail.
        let byId = Dictionary(summary.unfinished.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in finishing {
            guard let task = byId[id], task.status != "completed" else { continue }
            await store.toggleComplete(task)
        }
        for id in dropping {
            guard let task = byId[id] else { continue }
            await store.delete(task)
        }
        for task in rolling {
            await store.rollToTomorrow(task, now: now)
        }
        // The undo banner from the last delete would otherwise outlive the sheet and offer to undo
        // one arbitrary item from a batch decision.
        store.clearUndo()
        EveningShutdown.recordClosed(now: now)
        working = false
        Haptics.success()
        onFinished?()
        dismiss()
    }
}

/// The Home entry point, shown only in the evening and only when there's something to close out.
struct EveningShutdownCard: View {
    let tasks: [TaskItem]
    var now: Date
    var store: TaskStore

    @State private var open = false

    private var summary: EveningShutdown.Summary {
        EveningShutdown.summary(tasks: tasks, now: now)
    }

    var body: some View {
        Button {
            Haptics.light()
            open = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x2E3B8C), Color(hex: 0x4B3F86)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 13, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Close out the day")
                        .font(.Offload.manrope(16, .bold))
                        .foregroundStyle(Color.Offload.text)
                    Text(EveningShutdown.headline(summary))
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Color.Offload.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offloadCard()
        }
        .buttonStyle(.pressable)
        .sheet(isPresented: $open) {
            EveningShutdownView(tasks: tasks, now: now, store: store)
        }
    }
}
