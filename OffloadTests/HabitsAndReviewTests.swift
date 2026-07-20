import Testing
import Foundation
@testable import Offload

/// Habit learning, weekly review, and the energy-aware planner. All derived from real history,
/// so all of it is pure and testable.
struct HabitsAndReviewTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ day: Int, _ hour: Int = 9) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func iso(_ day: Int, _ hour: Int = 9) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour))
    }

    private func completed(_ title: String, category: String = "Work", at day: Int, hour: Int = 9) -> TaskItem {
        var t = TaskItem(title: title, category: category, status: "completed")
        t.completedAt = iso(day, hour)
        return t
    }

    // MARK: Habit learning

    @Test("Nothing is claimed until there's enough history to mean it")
    func requiresEvidence() {
        let few = (1...4).map { completed("T\($0)", at: 17) }
        let habits = HabitLearning.learn(from: few, now: date(18), calendar: utcCalendar)
        #expect(!habits.isConfident)
        #expect(HabitLearning.observations(habits).isEmpty)   // silent, not speculative
    }

    @Test("Peak hour is the hour you actually finish things")
    func peakHour() {
        var tasks = (1...10).map { completed("Evening \($0)", at: 17, hour: 20) }
        tasks += (1...3).map { completed("Morning \($0)", at: 17, hour: 8) }
        let habits = HabitLearning.learn(from: tasks, now: date(18), calendar: utcCalendar)
        #expect(habits.peakHour == 20)
        #expect(habits.isConfident)
    }

    @Test("Neglected categories are the ones that pile up unfinished")
    func neglectedCategories() {
        var tasks = (1...10).map { completed("Work \($0)", category: "Work", at: 17) }
        tasks += (1...6).map { TaskItem(title: "Admin \($0)", category: "Finance") }   // all open
        let habits = HabitLearning.learn(from: tasks, now: date(18), calendar: utcCalendar)
        #expect(habits.neglectedCategories.contains("Finance"))
        #expect(habits.reliableCategories.contains("Work"))
    }

    @Test("Effort estimates are only corrected on consistent, meaningful bias")
    func effortCorrection() {
        var confident = HabitLearning.Habits()
        confident.sampleSize = 20

        // Mild bias is left alone — the model's estimate isn't worth overriding.
        confident.effortBias = 1.1
        #expect(HabitLearning.adjustedEffort(30, habits: confident) == 30)

        // Strong, consistent underestimation gets padded.
        confident.effortBias = 1.5
        #expect(HabitLearning.adjustedEffort(30, habits: confident) == 45)

        // And never wildly — capped at 2x.
        confident.effortBias = 8.0
        #expect(HabitLearning.adjustedEffort(30, habits: confident) == 60)

        // Without enough history, nothing is touched.
        var green = HabitLearning.Habits()
        green.effortBias = 2.0
        green.sampleSize = 3
        #expect(HabitLearning.adjustedEffort(30, habits: green) == 30)
    }

    // MARK: Week review

    @Test("Repeatedly deferred work is called out by name")
    func deferredWork() {
        var task = TaskItem(title: "Call the accountant", createdAt: iso(1))
        task.dueDate = iso(25)      // pushed weeks past when it was captured
        let findings = WeekReview.findings(tasks: [task], now: date(18), calendar: utcCalendar)
        #expect(findings.chronicallyDeferred == ["Call the accountant"])
        #expect(WeekReview.observations(findings).contains { $0.contains("keep pushing") })
    }

    @Test("Old undated work is flagged as stale")
    func staleWork() {
        let task = TaskItem(title: "Someday idea", createdAt: iso(1))   // undated, 17 days old
        let findings = WeekReview.findings(tasks: [task], now: date(25), calendar: utcCalendar)
        #expect(findings.stale == ["Someday idea"])
    }

    @Test("Capturing far more than you close suggests taking on less")
    func overloadedWeek() {
        var tasks = [completed("One thing", at: 17)]
        tasks += (1...9).map { TaskItem(title: "Open \($0)", createdAt: iso(17)) }
        let findings = WeekReview.findings(tasks: tasks, now: date(18), calendar: utcCalendar)
        #expect(findings.completionRate < 0.3)
        #expect(WeekReview.observations(findings).contains { $0.contains("taking on less") })
    }

    @Test("A quiet week says so rather than inventing problems")
    func quietWeek() {
        let findings = WeekReview.findings(tasks: [], now: date(18), calendar: utcCalendar)
        #expect(findings.isEmpty)
        #expect(WeekReview.observations(findings) == ["A quiet week. Nothing needs untangling."])
    }

    // MARK: Energy-aware planning

    @Test("Demanding work is steered into your peak hours")
    func energyAwarePlacement() {
        let hard = TaskItem(title: "Deep work", priority: "high", effortMinutes: 60)
        let morning = EnergyProfile.morning

        // 9am is peak for a morning person; 6pm is not.
        #expect(EnergyProfile.penalty(for: hard, at: date(18, 9), profile: morning, calendar: utcCalendar) == 0)
        #expect(EnergyProfile.penalty(for: hard, at: date(18, 18), profile: morning, calendar: utcCalendar) == 2)
    }

    @Test("Light admin is nudged out of peak hours rather than squatting there")
    func adminAvoidsPeak() {
        let admin = TaskItem(title: "File receipts", priority: "low", effortMinutes: 10)
        let morning = EnergyProfile.morning
        #expect(EnergyProfile.penalty(for: admin, at: date(18, 9), profile: morning, calendar: utcCalendar) == 1)
        #expect(EnergyProfile.penalty(for: admin, at: date(18, 18), profile: morning, calendar: utcCalendar) == 0)
    }

    @Test("Long tasks count as demanding even at normal priority")
    func longTasksAreDemanding() {
        #expect(EnergyProfile.isDemanding(TaskItem(title: "Big", effortMinutes: 60)))
        #expect(EnergyProfile.isDemanding(TaskItem(title: "Urgent", priority: "high")))
        #expect(!EnergyProfile.isDemanding(TaskItem(title: "Quick", priority: "low", effortMinutes: 10)))
    }

    @Test("Blocked work is never scheduled — you can't do it")
    func waitingExcludedFromPlan() {
        var waiting = TaskItem(title: "Sarah's review", priority: "high")
        waiting.status = "waiting"
        let candidates = DayPlanner.candidates(
            from: [waiting, TaskItem(title: "Mine to do")],
            on: date(18), now: date(18, 8), calendar: utcCalendar
        )
        #expect(candidates.map(\.title) == ["Mine to do"])
    }

    @Test("Blocked work weighs less on the mind than live work")
    func waitingWeighsLess() {
        var waiting = TaskItem(title: "Blocked", dueDate: iso(15))
        waiting.status = "waiting"
        let blocked = MentalLoad.compute(tasks: [waiting], now: date(18), calendar: utcCalendar)
        let live = MentalLoad.compute(tasks: [TaskItem(title: "Live", dueDate: iso(15))],
                                      now: date(18), calendar: utcCalendar)
        #expect(blocked.waiting == 1)
        #expect(blocked.score < live.score)
    }
}
