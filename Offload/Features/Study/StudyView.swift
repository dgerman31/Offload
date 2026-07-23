import SwiftUI
import GRDB

/// The Study tab — a med-school study organizer. Unlike Gym, nothing here is AI-planned: it's a
/// catalog of real subtopics (the user's own AnKing v12 collection) and study resources (First
/// Aid, UWorld, AMBOSS, Sketchy) picked from each morning. Picking one schedules it immediately
/// as a real task on today's schedule, through the exact same `AutoFit.fitIntoToday` pipeline
/// `AddTaskSheet` already uses — never a separate list off to the side.
///
/// Deliberately has no parallel "session" model the way Gym has `WorkoutSession`: Gym needs one
/// because a session carries real AI-written content (exercises, sets, reps) a task can't hold.
/// A study pick has no equivalent content — it's just "study this, for about this long" — so
/// each pick is simply an ordinary `TaskItem`, and several picks become several separate tasks.
///
/// First Aid/UWorld/AMBOSS/Sketchy are deliberately **not** part of the Anki subtopic tree at
/// all, and not tied to any system either — plain standalone quick-adds, per the user's explicit
/// "it has nothing to do with neuro repro and all that."
struct StudyView: View {
    @State private var store = TaskStore()
    @State private var appeared = false
    /// Systems whose Anki subtopic tree is currently hidden (collapsed).
    @State private var collapsedAnkiTrees: Set<String> = []
    /// Subtopics currently showing their leaves.
    @State private var expandedSubtopics: Set<String> = []
    /// Titles added *this session*, shown as added instantly rather than waiting on the store's
    /// round trip through the database and back — the whole point being immediate confirmation
    /// that a tap registered.
    @State private var optimisticallyAdded: Set<String> = []

    private var accent: Color { Color.Offload.accent(for: StudyCatalog.category) }

    /// Titles of today's already-scheduled Study tasks, unioned with this session's optimistic
    /// set — matched by the deterministic title `StudyCatalog` always builds, so a row can show
    /// "already on today's schedule" without any hidden bookkeeping field. Not a hard block: the
    /// user intentionally redoes subtopics as they unsuspend more of the deck.
    private var addedTitles: Set<String> {
        let cal = Calendar.current
        let today = Date()
        let fromStore = Set(store.allTasks.compactMap { task -> String? in
            guard task.category == StudyCatalog.category else { return nil }
            guard let due = DueDate.parse(task.dueDate), cal.isDate(due, inSameDayAs: today) else { return nil }
            return task.title
        })
        return fromStore.union(optimisticallyAdded)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header.appearIn(0, when: appeared)
                    quickAddSection.appearIn(1, when: appeared)
                    ForEach(Array(StudySystem.allCases.enumerated()), id: \.element) { index, system in
                        systemCard(system)
                            .appearIn(min(index + 2, 8), when: appeared)
                            .scrollAppear()
                    }
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .task { await store.observe() }
            .task { await store.loadEvents(around: Date()) }
            .task { withAnimation(Motion.settle) { appeared = true } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("What are you studying today?")
                .font(.Offload.manrope(20, .bold))
                .foregroundStyle(Color.Offload.text)
            Text("Pick anything below — it schedules straight onto today.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick add — completely separate from the Anki systems below

    /// First Aid, UWorld, AMBOSS, and Sketchy live here, not inside any system card — the user
    /// was explicit these "have nothing to do with neuro repro and all that." One tap schedules
    /// a plain, generic block; there's no subtopic or system involved at all.
    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("QUICK ADD", systemImage: "bolt.fill")
                .font(.caption2).fontWeight(.bold).tracking(0.8)
                .foregroundStyle(Color.Offload.muted)

            ambossMixedReviewButton

            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(StudyResource.allCases) { resource in
                    resourceQuickAddButton(resource)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private var ambossMixedReviewButton: some View {
        let added = addedTitles.contains(StudyCatalog.ambossMixedReviewTitle)
        return Button {
            addOptimistically(StudyCatalog.ambossMixedReviewTitle)
            Task { await addAtEndOfDay(StudyCatalog.makeAmbossMixedReviewTask()) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [Color.Offload.indigo, accent],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 13, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("AMBOSS Mixed Review")
                        .font(.Offload.manrope(15, .bold))
                        .foregroundStyle(Color.Offload.text)
                    Text("10 questions · ~25 min · lands at the end of today")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 0)
                addGlyph(added)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.pressable(scale: 0.98))
        .sensoryFeedback(.success, trigger: added)
    }

    private func resourceQuickAddButton(_ resource: StudyResource) -> some View {
        let added = addedTitles.contains(resource.rawValue)
        let (minutes, note) = resource.plan
        return Button {
            addOptimistically(resource.rawValue)
            Task { await add(StudyCatalog.makeResourceTask(resource)) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: resource.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(resource.rawValue).font(.caption).fontWeight(.semibold).foregroundStyle(accent)
                    Text("\(note) · \(Self.durationLabel(minutes))")
                        .font(.system(size: 10)).foregroundStyle(accent).opacity(0.75)
                }
                addGlyph(added)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(accent.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.pressable(scale: 0.93))
        .sensoryFeedback(.success, trigger: added)
    }

    // MARK: System cards

    private func systemCard(_ system: StudySystem) -> some View {
        let ankiHidden = collapsedAnkiTrees.contains(system.id)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(Motion.snappy) {
                    if ankiHidden { collapsedAnkiTrees.remove(system.id) } else { collapsedAnkiTrees.insert(system.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: system.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(system.rawValue.uppercased())
                        .font(.caption).fontWeight(.bold).tracking(0.8)
                        .foregroundStyle(Color.Offload.muted)
                    Spacer(minLength: 0)
                    Text("\(system.totalAnkiCards) Anki cards")
                        .font(.caption).foregroundStyle(Color.Offload.muted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Offload.muted)
                        .rotationEffect(.degrees(ankiHidden ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !ankiHidden {
                VStack(spacing: 2) {
                    ForEach(system.subtopics) { subtopic in
                        subtopicRow(system, subtopic)
                        if subtopic.id != system.subtopics.last?.id {
                            Rectangle().fill(Color.Offload.divider).frame(height: 1)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
        .animation(Motion.snappy, value: ankiHidden)
    }

    private func subtopicRow(_ system: StudySystem, _ subtopic: StudySubtopic) -> some View {
        let leavesShown = expandedSubtopics.contains(subtopic.id)
        let title = StudyCatalog.ankiTitle(system: system, nodeName: subtopic.name)
        let added = addedTitles.contains(title)
        return VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(Motion.snappy) {
                        if leavesShown { expandedSubtopics.remove(subtopic.id) } else { expandedSubtopics.insert(subtopic.id) }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subtopic.name)
                                .font(.Offload.taskTitle)
                                .foregroundStyle(Color.Offload.text)
                            Text("\(subtopic.ankiCardCount) cards · \(Self.durationLabel(StudyCatalog.ankiMinutes(forCards: subtopic.ankiCardCount)))")
                                .font(.Offload.data)
                                .foregroundStyle(Color.Offload.muted)
                        }
                        Spacer(minLength: 8)
                        if !subtopic.leaves.isEmpty {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.Offload.muted)
                                .rotationEffect(.degrees(leavesShown ? 0 : -90))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    addOptimistically(title)
                    Task { await add(StudyCatalog.makeAnkiTask(system: system, nodeName: subtopic.name, cardCount: subtopic.ankiCardCount)) }
                } label: {
                    addGlyph(added)
                }
                .buttonStyle(.pressable(scale: 0.85))
                .sensoryFeedback(.success, trigger: added)
            }
            .padding(.vertical, 8)

            if leavesShown {
                VStack(spacing: 6) {
                    ForEach(subtopic.leaves) { leaf in
                        leafRow(system, leaf)
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.snappy, value: leavesShown)
    }

    private func leafRow(_ system: StudySystem, _ leaf: StudyLeaf) -> some View {
        let title = StudyCatalog.ankiTitle(system: system, nodeName: leaf.name)
        let added = addedTitles.contains(title)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(leaf.name)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.text)
                Text("\(leaf.ankiCardCount) cards · \(Self.durationLabel(StudyCatalog.ankiMinutes(forCards: leaf.ankiCardCount)))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer(minLength: 8)
            Button {
                addOptimistically(title)
                Task { await add(StudyCatalog.makeAnkiTask(system: system, nodeName: leaf.name, cardCount: leaf.ankiCardCount)) }
            } label: {
                addGlyph(added)
            }
            .buttonStyle(.pressable(scale: 0.85))
            .sensoryFeedback(.success, trigger: added)
        }
    }

    // MARK: Shared bits

    /// The same "+" → filled green checkmark treatment everywhere something can be added —
    /// tapping it is the entire interaction, and it flips the instant you tap it.
    private func addGlyph(_ added: Bool) -> some View {
        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(added ? Color.Offload.green : Color.Offload.muted)
    }

    static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }

    // MARK: Adding

    /// Mark a title added right now, in this view's own state — instant visual confirmation
    /// that the tap registered, independent of how long the database round trip takes.
    private func addOptimistically(_ title: String) {
        Haptics.light()
        optimisticallyAdded.insert(title)
    }

    /// Schedule a freshly built study task exactly like `AddTaskSheet.add()` does: give it a
    /// real slot in today's open time right away (the same `AutoFit` pipeline, same past-cutoff
    /// roll-to-tomorrow behavior), rather than letting it sit unplaced.
    private func add(_ task: TaskItem) async {
        let existing = (try? await AppDatabase.shared.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []
        let fitted = AutoFit.fitIntoToday(new: [task], existing: existing,
                                          cutoffHour: DayPlanner.storedDayEndHour()).first ?? task
        await TaskActions.create(fitted)
    }

    /// The nightly AMBOSS review always lands after everything else already on today's
    /// schedule — a wind-down block, not something that should compete for an earlier open
    /// slot the way AutoFit's earliest-fit search would place it.
    private func addAtEndOfDay(_ task: TaskItem) async {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        var latestEnd = cal.date(bySettingHour: DayPlanner.storedDayEndHour(), minute: 0, second: 0, of: today) ?? today

        for existing in store.allTasks {
            guard existing.status != "completed", !existing.dueIsAllDay,
                  let start = DueDate.parse(existing.dueDate), cal.isDate(start, inSameDayAs: today) else { continue }
            let end = cal.date(byAdding: .minute, value: existing.effortMinutes ?? 30, to: start) ?? start
            if end > latestEnd { latestEnd = end }
        }
        for event in store.todayEvents where event.end > latestEnd {
            latestEnd = event.end
        }

        var toSave = task
        toSave.dueDate = DueDate.canonicalString(from: max(latestEnd, now))
        toSave.dueIsAllDay = false
        toSave.pinned = false
        await TaskActions.create(toSave)
    }
}

#Preview {
    StudyView()
}
