import SwiftUI
import GRDB

/// One observation's worth of state. A named `Sendable` struct rather than a tuple, because a
/// `ValueObservation` value crosses out of the database's context to reach the main actor.
struct HabitSnapshot: Sendable {
    var habits: [Habit]
    var checks: [HabitCheck]
}

/// Today's habits, and their ticks.
///
/// Observed rather than fetched once, so ticking one on Home and ticking it in the editor sheet
/// can't disagree. Today is derived from a day key rather than stored, which is what makes the
/// list reset at midnight without anything having to run at midnight.
@MainActor
@Observable
final class HabitStore {
    private(set) var habits: [Habit] = []
    /// The last couple of days of ticks. `checkedToday` is derived from these against `todayKey`
    /// rather than stored, so the list resets at midnight without anything having to run at
    /// midnight — the key changes and the same rows stop counting.
    private(set) var recentChecks: [HabitCheck] = []
    private(set) var todayKey = HabitProgress.dayKey(Date())

    private let db: AppDatabase
    private var started = false

    init(db: AppDatabase = .shared) { self.db = db }

    var checkedToday: Set<String> { HabitProgress.checkedIds(recentChecks, on: todayKey) }
    var total: Int { habits.count }
    var done: Int { habits.filter { checkedToday.contains($0.id) }.count }
    var allDone: Bool { total > 0 && done == total }

    /// Nudge the day key forward. Called from the card's slow ticker, so an app left open past
    /// midnight rolls over on its own.
    func refreshDay(now: Date = Date()) {
        let key = HabitProgress.dayKey(now)
        if key != todayKey { todayKey = key }
    }

    func observe() async {
        guard !started else { return }
        started = true
        // A recent window of ticks rather than the whole history, which grows without bound. Five
        // weeks: enough for the row of dots and a streak, and it comfortably spans midnight so a
        // tick made at 11:59 is still in hand when the day key rolls over.
        let observation = ValueObservation.tracking { database -> HabitSnapshot in
            let habits = try Habit
                .filter(Column("deleted") == false)
                .order(Column("sort_order"))
                .fetchAll(database)
            let window = TimeInterval(HabitProgress.checkWindowDays) * 86_400
            let cutoff = WakeTracker.dayKey(Date().addingTimeInterval(-window), calendar: .current)
            let checks = try HabitCheck.filter(Column("day") >= cutoff).fetchAll(database)
            return HabitSnapshot(habits: habits, checks: checks)
        }
        do {
            for try await snapshot in observation.values(in: db.dbQueue) {
                habits = snapshot.habits
                recentChecks = snapshot.checks
                refreshDay()
            }
        } catch {
            Log.database.error("Habit observation stopped: \(CaptureService.errorKind(error), privacy: .public)")
        }
        // Released once the stream ends — `.task` cancels this when the card disappears (switching
        // tabs, pushing a detail), and without clearing the latch the next `.task` would return
        // immediately and leave the card frozen on whatever it last saw. Same as `SharedTasks`.
        started = false
    }

    /// Tick or untick for today. Unticking deletes the row — a tick is the row's existence, so
    /// there's no flag that can drift out of step with it.
    ///
    /// The database decides which way the toggle goes, not the cached `checkedToday`: delete the
    /// tick if it's there, insert it if it isn't. If the view's copy were the one deciding and it
    /// had gone stale, a second tap would try to insert a row the unique index already forbids,
    /// and the tick would fail silently from then on.
    func toggle(_ habit: Habit, now: Date = Date()) async {
        let day = HabitProgress.dayKey(now)
        let habitId = habit.id
        do {
            let ticked = try await db.dbQueue.write { database -> Bool in
                let removed = try HabitCheck
                    .filter(Column("habit_id") == habitId && Column("day") == day)
                    .deleteAll(database)
                guard removed == 0 else { return false }
                try HabitCheck(habitId: habitId, day: day).insert(database)
                return true
            }
            if ticked { Haptics.success() } else { Haptics.light() }
        } catch {
            Log.database.error("Habit tick failed: \(CaptureService.errorKind(error), privacy: .public)")
        }
    }

    func add(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let habit = Habit(title: trimmed, sortOrder: (habits.map(\.sortOrder).max() ?? 0) + 1)
        try? await db.dbQueue.write { try habit.insert($0) }
    }

    /// Soft delete, so the tick history a streak would be built from survives.
    func delete(_ habit: Habit) async {
        var gone = habit
        gone.deleted = true
        // An immutable copy, not the `var`: GRDB's async `write` closure is `@Sendable` and can't
        // capture mutable state. Same convention as every other write in the app.
        let toSave = gone
        try? await db.dbQueue.write { try toSave.update($0) }
    }

    func seedDefaults() async {
        let starters = HabitProgress.suggestedDefaults()
        try? await db.dbQueue.write { database in
            for habit in starters { try habit.insert(database) }
        }
        Haptics.success()
    }
}

/// The Home card: every habit for today, ticked in place.
///
/// Tapping a row toggles it — no navigation, because the whole point is that it costs one tap. The
/// nudge line appears only late in the day and only when something's outstanding; see
/// `HabitProgress.nudge`.
struct DailyHabitsCard: View {
    @State private var store = HabitStore()
    @State private var managing = false
    @State private var now = Date()

    private var nudge: String? {
        HabitProgress.nudge(habits: store.habits, checkedIds: store.checkedToday, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Every day", systemImage: "repeat.circle.fill")
                    .font(.caption).fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(Color.Offload.teal)
                Spacer()
                if store.total > 0 {
                    Text(HabitProgress.summary(done: store.done, total: store.total))
                        .font(.Offload.data)
                        .foregroundStyle(store.allDone ? Color.Offload.green : Color.Offload.muted)
                }
                Button { managing = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Offload.muted)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Edit habits")
            }

            if store.habits.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(store.habits) { habit in
                        row(habit)
                    }
                }
                if let nudge {
                    Text(nudge)
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if store.allDone {
                    Label("All done today.", systemImage: "checkmark.seal.fill")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.green)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .task { await store.observe() }
        // Re-read the clock periodically so the nudge appears on its own once the evening arrives,
        // rather than only after the screen happens to be rebuilt for some other reason.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                now = Date()
                store.refreshDay(now: now)
            }
        }
        .animation(Motion.standard, value: store.done)
        .animation(Motion.standard, value: nudge)
        .sheet(isPresented: $managing) {
            NavigationStack { HabitEditorView(store: store) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The things you want to do every day — water, stretching, whatever matters.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await store.seedDefaults() }
                } label: {
                    Label("Start with a few", systemImage: "wand.and.stars")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.Offload.teal, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
                Button { managing = true } label: {
                    Text("Add my own")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Color.Offload.muted)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func row(_ habit: Habit) -> some View {
        let done = store.checkedToday.contains(habit.id)
        return Button {
            Task { await store.toggle(habit) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(done ? Color.Offload.green : Color.Offload.muted.opacity(0.55))
                    .symbolEffect(.bounce, value: done)
                Image(systemName: habit.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(done ? Color.Offload.muted : Color.Offload.teal)
                    .frame(width: 18)
                Text(habit.title)
                    .font(.Offload.body)
                    .strikethrough(done, color: Color.Offload.muted)
                    .foregroundStyle(done ? Color.Offload.muted : Color.Offload.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                history(habit)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The last week, and the run you're on. Sits at the trailing edge and stays small on purpose:
    /// the card is a checklist first, and a streak that shouts is a streak you start protecting
    /// instead of a habit you keep.
    private func history(_ habit: Habit) -> some View {
        let streak = HabitProgress.streak(store.recentChecks, habitId: habit.id, now: now)
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(HabitProgress.week(store.recentChecks, habitId: habit.id, now: now).enumerated()),
                        id: \.offset) { _, ticked in
                    Circle()
                        .fill(ticked ? Color.Offload.teal : Color.Offload.muted.opacity(0.22))
                        .frame(width: 5, height: 5)
                }
            }
            // Two days isn't a streak, it's a coincidence — so nothing is said until three.
            if streak >= 3 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill").font(.system(size: 9))
                    Text("\(streak)").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Color.Offload.amber)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Add, rename-by-deleting, and remove habits. Deliberately plain — this screen exists so the card
/// stays a checklist rather than growing edit affordances into every row.
struct HabitEditorView: View {
    let store: HabitStore
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""

    var body: some View {
        List {
            Section {
                ForEach(store.habits) { habit in
                    HStack(spacing: 10) {
                        Image(systemName: habit.symbol)
                            .foregroundStyle(Color.Offload.teal)
                            .frame(width: 22)
                        Text(habit.title)
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { store.habits[$0] }
                    Task { for habit in doomed { await store.delete(habit) } }
                }
            } header: {
                Text("Every day")
            } footer: {
                Text("Removing one keeps the days you already ticked it, so streaks stay intact if you add it back.")
            }

            Section("Add one") {
                HStack {
                    TextField("Drink a gallon of water", text: $newTitle)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                    if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Add") { commit() }
                            .font(.caption).fontWeight(.semibold)
                    }
                }
            }
        }
        .navigationTitle("Daily habits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func commit() {
        let title = newTitle
        newTitle = ""
        Task { await store.add(title: title) }
        Haptics.light()
    }
}
