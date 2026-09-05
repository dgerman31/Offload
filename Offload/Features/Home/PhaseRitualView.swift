import SwiftUI

/// One of the day's three rituals, taking over the screen for as long as it takes to answer it.
///
/// ### The change this represents
///
/// Home used to *be* these screens — the clock picked one and that was the app's front door, with
/// everything else behind a button. That got the emphasis backwards. The full picture is what you
/// open the app for ninety-five times out of a hundred; the ritual is the exception, and an
/// exception belongs on top of the main screen rather than in place of it.
///
/// So `EverythingView` is Home now, and this arrives over it at the three moments a day that
/// genuinely want the whole screen: **decide the day**, **close it out**, **put it down**. Each one
/// appears once. Acting on it ends it, and so does "Not now" — a prompt you waved away and a prompt
/// you answered have the same answer to "should this take over again in ten minutes."
///
/// `.midday` is reachable here on demand but never arrives by itself: "do the next thing" isn't a
/// ritual, it's just the day.
struct PhaseRitualView: View {
    let phase: DayPhase
    /// True when the clock brought this here, false when you asked for it from the menu. A ritual
    /// you went looking for shouldn't be marked as today's turn used up.
    var isAutomatic = true

    @Environment(\.dismiss) private var dismiss
    @Environment(CaptureCoordinator.self) private var capture

    @State private var store = TaskStore()
    @State private var now = Date()
    @State private var planning = false
    @State private var closing = false
    @State private var skipped: Set<String> = []
    /// The occasional one-question interview — see `LifeBriefInterview`. Usually nil. It lives on
    /// the morning ritual because that's the one moment a day the app has your attention for
    /// something reflective, and because a question on the main Home screen would be there every
    /// time you glanced at it.
    @State private var briefQuestion: LifeBriefQuestion?

    @AppStorage(DayPhase.plannedDayKey) private var plannedDay = ""
    @AppStorage(EveningShutdown.lastClosedKey) private var lastClosedDay = ""

    var body: some View {
        NavigationStack {
            ZStack {
                phase.wash
                surface
            }
            .navigationTitle(phase.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Not now" rather than "Close": it's an answer, not an escape. And it's the
                    // only control here that has to be obvious, because a takeover you can't
                    // dismiss instantly is a takeover you resent by the third day.
                    Button(isAutomatic ? "Not now" : "Done") { finish() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { capture.beginCapture() } label: {
                        Image(systemName: "bolt.circle.fill").font(.title2)
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("Quick Capture")
                }
            }
            .task { await store.observe() }
            .task { await store.loadEvents(around: now) }
            .task { considerAsking() }
            .sheet(isPresented: $planning) {
                DayPlanView(tasks: store.allTasks, events: store.rangeEvents, day: now) {
                    plannedDay = DayPhase.dayKey(now)
                    Task { await NotificationSync.shared.refresh() }
                    finish()
                }
            }
            .sheet(isPresented: $closing) {
                EveningShutdownView(tasks: store.allTasks, now: now, store: store) {
                    finish()
                }
            }
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch phase {
        case .morning:
            MorningSurface(items: timeline, now: now,
                           question: briefQuestion,
                           onPlan: { planning = true },
                           onCommit: {
                               plannedDay = DayPhase.dayKey(now)
                               Haptics.success()
                               finish()
                           },
                           onAnswerQuestion: answerBriefQuestion,
                           onDismissQuestion: dismissBriefQuestion)
        case .midday:
            let current = middayTask()
            MiddaySurface(
                task: current,
                next: nextUp(after: current),
                onFocus: { chosen in
                    FocusTimer.shared.start(task: chosen)
                    FocusTimer.shared.isExpanded = true
                    finish()
                },
                onDone: { chosen in
                    Haptics.success()
                    Task { await store.toggleComplete(chosen) }
                },
                onPickAnother: {
                    if let current {
                        skipped.insert(current.id)
                        Haptics.light()
                    }
                },
                onCapture: { capture.beginCapture() }
            )
        case .evening:
            EveningSurface(
                summary: EveningShutdown.summary(tasks: store.allTasks, now: now),
                closed: lastClosedDay == DayPhase.dayKey(now),
                onCloseOut: { closing = true },
                onWrite: { capture.beginCapture() }
            )
        case .night:
            NightSurface(onFinished: finish)
        }
    }

    // MARK: The occasional question

    /// Asking is recorded the moment the question is *shown*, not when it's answered — otherwise an
    /// ignored one comes back every single morning, which is the nagging this is built to avoid.
    private func considerAsking() {
        guard phase == .morning, briefQuestion == nil else { return }
        let brief = LifeBrief.stored()
        guard let question = LifeBriefInterview.next(brief: brief, now: now) else { return }
        LifeBrief.save(LifeBriefInterview.recordAsked(question, in: brief, now: now))
        withAnimation(Motion.standard) { briefQuestion = question }
    }

    private func answerBriefQuestion(_ answer: String) {
        guard let question = briefQuestion else { return }
        LifeBrief.save(LifeBriefInterview.recordAnswered(question, answer: answer,
                                                         in: LifeBrief.stored(), now: now))
        Haptics.success()
        withAnimation(Motion.standard) { briefQuestion = nil }
    }

    private func dismissBriefQuestion() {
        guard let question = briefQuestion else { return }
        LifeBrief.save(LifeBriefInterview.recordDismissed(question, in: LifeBrief.stored(), now: now))
        withAnimation(Motion.standard) { briefQuestion = nil }
    }

    /// End the ritual, and record that it's had its turn today.
    private func finish() {
        if isAutomatic {
            DayPhase.markHandled(phase, now: now)
        }
        dismiss()
    }

    // MARK: The day, for the surfaces that need it

    private var timeline: [DayItem] {
        DayTimeline.items(tasks: store.allTasks, events: store.todayEvents, on: now)
    }

    private func middayTask(calendar: Calendar = .current) -> TaskItem? {
        let startOfToday = calendar.startOfDay(for: now)
        let roots = HomeGrouping.rootsOnly(store.openTasks.filter { !$0.deleted })
        let todays = roots.filter { task in
            guard let due = DueDate.parse(task.dueDate) else { return false }
            return due < startOfToday || calendar.isDate(due, inSameDayAs: now)
        }
        let pool = todays.isEmpty ? roots : todays
        let remaining = pool.filter { !skipped.contains($0.id) }
        return NextBest.pick(from: remaining.isEmpty ? pool : remaining)
    }

    private func nextUp(after current: TaskItem?) -> DayItem? {
        timeline.first { item in
            if item.taskId == current?.id { return false }
            if let time = item.time, time <= now { return false }
            return true
        }
    }
}
