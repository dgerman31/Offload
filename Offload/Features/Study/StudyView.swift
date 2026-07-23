import SwiftUI
import GRDB

/// The Study tab — a med-school study organizer. Unlike Gym, nothing here is AI-planned: it's a
/// catalog of real subtopics (the user's own AnKing v12 collection) and study resources (Anki,
/// First Aid, UWorld, AMBOSS, Sketchy) picked from each morning. Picking one schedules it
/// immediately as a real task on today's schedule, through the exact same
/// `AutoFit.fitIntoToday` pipeline `AddTaskSheet` already uses — never a separate list off to
/// the side.
///
/// Deliberately has no parallel "session" model the way Gym has `WorkoutSession`: Gym needs one
/// because a session carries real AI-written content (exercises, sets, reps) a task can't hold.
/// A study pick has no equivalent content — it's just "study this, for about this long" — so
/// each pick is simply an ordinary `TaskItem`, and several picks become several separate tasks
/// (confirmed with the user, who wanted them entered that way rather than batched).
struct StudyView: View {
    @State private var store = TaskStore()
    @State private var expandedSubtopic: String?
    @State private var appeared = false
    @State private var justAddedTitle: String?

    private var accent: Color { Color.Offload.accent(for: StudyCatalog.category) }

    /// Titles of today's already-scheduled Study tasks — matched by the deterministic title
    /// `StudyCatalog` always builds, so a resource button can show "already on today's
    /// schedule" without any hidden bookkeeping field. Not a hard block: the user intentionally
    /// redoes subtopics as they unsuspend more of the deck, so tapping again just adds another.
    private var todayTitles: Set<String> {
        let cal = Calendar.current
        let today = Date()
        return Set(store.allTasks.compactMap { task -> String? in
            guard task.category == StudyCatalog.category else { return nil }
            guard let due = DueDate.parse(task.dueDate), cal.isDate(due, inSameDayAs: today) else { return nil }
            return task.title
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header.appearIn(0, when: appeared)
                    ambossQuickAdd.appearIn(1, when: appeared)
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
            .task { withAnimation(Motion.settle) { appeared = true } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("STEP 1")
                .font(.caption2).fontWeight(.bold).tracking(1.1)
                .foregroundStyle(accent)
            Text("What are you studying today?")
                .font(.Offload.manrope(20, .bold))
                .foregroundStyle(Color.Offload.text)
            Text("Pick anything below — it schedules straight onto today.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AMBOSS quick add

    private var ambossQuickAdd: some View {
        let added = todayTitles.contains(StudyCatalog.ambossMixedReviewTitle)
        return Button {
            Task { await add(StudyCatalog.makeAmbossMixedReviewTask()) }
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
                        .font(.Offload.manrope(16, .bold))
                        .foregroundStyle(Color.Offload.text)
                    Text("10 questions · ~25 min · every night")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 0)
                addedBadge(added)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offloadCard()
        }
        .buttonStyle(.pressable(scale: 0.98))
        .sensoryFeedback(.success, trigger: justAddedTitle) { _, new in new == StudyCatalog.ambossMixedReviewTitle }
    }

    // MARK: System cards

    private func systemCard(_ system: StudySystem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: system.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Text(system.rawValue.uppercased())
                    .font(.caption).fontWeight(.bold).tracking(0.8)
                    .foregroundStyle(Color.Offload.muted)
                Spacer(minLength: 0)
                Text("\(system.totalAnkiCards) cards")
                    .font(.caption).foregroundStyle(Color.Offload.muted)
            }
            .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(system.subtopics) { subtopic in
                    subtopicRow(system, subtopic)
                    if subtopic.id != system.subtopics.last?.id {
                        Rectangle().fill(Color.Offload.divider).frame(height: 1)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private func subtopicRow(_ system: StudySystem, _ subtopic: StudySubtopic) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedSubtopic == subtopic.id },
                set: { expandedSubtopic = $0 ? subtopic.id : nil }
            )
        ) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(StudyResource.allCases) { resource in
                    resourceChip(system, subtopic, resource)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subtopic.name)
                        .font(.Offload.taskTitle)
                        .foregroundStyle(Color.Offload.text)
                    Text("\(subtopic.ankiCardCount) Anki cards")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .tint(Color.Offload.muted)
        .animation(Motion.snappy, value: expandedSubtopic)
    }

    private func resourceChip(_ system: StudySystem, _ subtopic: StudySubtopic, _ resource: StudyResource) -> some View {
        let title = StudyCatalog.title(system: system, subtopic: subtopic, resource: resource)
        let added = todayTitles.contains(title)
        let (minutes, note) = resource.plan(for: subtopic)
        return Button {
            Task { await add(StudyCatalog.makeTask(system: system, subtopic: subtopic, resource: resource)) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: resource.icon)
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(resource.rawValue)
                        .font(.caption).fontWeight(.semibold)
                    Text("\(note) · \(Self.durationLabel(minutes))")
                        .font(.system(size: 10))
                        .opacity(0.75)
                }
                if added {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(added ? accent.opacity(0.9) : accent.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))
            .foregroundStyle(added ? .white : accent)
        }
        .buttonStyle(.pressable(scale: 0.93))
        .sensoryFeedback(.success, trigger: justAddedTitle) { _, new in new == title }
    }

    // MARK: Adding

    private func addedBadge(_ added: Bool) -> some View {
        Group {
            if added {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.Offload.green)
            } else {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.Offload.muted)
            }
        }
    }

    static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
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
        justAddedTitle = task.title
    }
}

#Preview {
    StudyView()
}
