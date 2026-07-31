import Testing
import Foundation
@testable import Offload

/// The learned profile: what gets concluded from a history, and what refuses to be concluded.
struct LearnedProfileTests {

    private func finished(_ title: String, estimate: Int, spent: Int, category: String? = nil)
        -> (TaskItem, TaskSession) {
        var task = TaskItem(title: title, category: category, effortMinutes: estimate)
        task.status = "completed"
        let session = TaskSession(taskId: task.id, category: category,
                                  startedAt: "2026-07-29T09:00:00Z", endedAt: "2026-07-29T10:00:00Z",
                                  plannedMinutes: 25, actualMinutes: spent, ranToCompletion: true)
        return (task, session)
    }

    private func history(count: Int, estimate: Int, spent: Int, category: String? = nil)
        -> ([TaskItem], [TaskSession]) {
        var tasks: [TaskItem] = []
        var sessions: [TaskSession] = []
        for i in 0..<count {
            let (t, s) = finished("Job \(i)", estimate: estimate, spent: spent, category: category)
            tasks.append(t)
            sessions.append(s)
        }
        return (tasks, sessions)
    }

    // MARK: Applying drift

    @Test("A thin history changes nothing, however lopsided it looks")
    func noAdjustmentWithoutEvidence() {
        var profile = LearnedProfile()
        profile.driftOverall = 2.0
        profile.finishedTaskSample = 4          // one short of the gate
        #expect(profile.adjustment(minutes: 60, category: nil) == nil)
        #expect(profile.plannedMinutes(for: TaskItem(title: "x", effortMinutes: 60)) == 60)
    }

    @Test("A real bias stretches the block, and says why")
    func stretchesAndExplains() {
        var profile = LearnedProfile()
        profile.driftOverall = 1.4
        profile.finishedTaskSample = 9

        let adjustment = profile.adjustment(minutes: 60, category: "Work")
        #expect(adjustment?.adjusted == 85)      // 84 → nearest five
        #expect(adjustment?.base == 60)
        #expect(adjustment?.percent == 40)
        #expect(adjustment?.reason == "Your Work runs about 40% long.")
    }

    @Test("A category with its own history beats the overall figure")
    func categoryWins() {
        var profile = LearnedProfile()
        profile.driftOverall = 1.5
        profile.driftByCategory = ["Personal": 1.0]
        profile.finishedTaskSample = 12

        #expect(profile.drift(for: "Personal") == 1.0)
        #expect(profile.drift(for: "Work") == 1.5)      // no Personal history, falls back
        #expect(profile.adjustment(minutes: 60, category: "Personal") == nil)
    }

    @Test("Small corrections aren't worth making")
    func ignoresNoise() {
        var profile = LearnedProfile()
        profile.driftOverall = 1.05
        profile.finishedTaskSample = 20
        // Silently moving 60 minutes to 63 is noise dressed as intelligence.
        #expect(profile.adjustment(minutes: 60, category: nil) == nil)
    }

    @Test("A wild multiplier is clamped rather than obeyed")
    func clampsExtremes() {
        var profile = LearnedProfile()
        profile.driftOverall = 6.0
        profile.finishedTaskSample = 20
        // Never more than double: the honest response to a 6× ratio is to fix the estimate, not
        // to hand the day over to it.
        #expect(profile.adjustment(minutes: 60, category: nil)?.adjusted == 120)

        profile.driftOverall = 0.1
        #expect(profile.adjustment(minutes: 60, category: nil)?.adjusted == 35)   // 0.6 floor → 36 → 35
    }

    // MARK: Storage

    @Test("A profile round-trips, and can be forgotten")
    func storage() {
        let defaults = UserDefaults(suiteName: "learned-profile-\(UUID().uuidString)")!
        #expect(LearnedProfile.stored(defaults: defaults) == LearnedProfile())

        var profile = LearnedProfile()
        profile.driftOverall = 1.4
        profile.finishedTaskSample = 9
        profile.peakHours = [8, 9, 10]
        profile.glossary = ["REDCap", "OSCE"]
        LearnedProfile.save(profile, defaults: defaults)

        let loaded = LearnedProfile.stored(defaults: defaults)
        #expect(loaded.driftOverall == 1.4)
        #expect(loaded.peakHours == [8, 9, 10])
        #expect(loaded.glossary == ["REDCap", "OSCE"])

        LearnedProfile.forget(defaults: defaults)
        #expect(LearnedProfile.stored(defaults: defaults).driftOverall == nil)
    }

    // MARK: The whole pass

    @Test("The pass only records a category's own evidence, never the fallback")
    func perCategoryEvidenceIsNotFabricated() {
        // Work has plenty; Personal has one task. `TaskSessionLog.drift` would hand back the
        // overall figure for Personal, which is right at a call site and wrong to store — it would
        // make a category with no history look independently confident.
        let (workTasks, workSessions) = history(count: 8, estimate: 60, spent: 90, category: "Work")
        let (oneTask, oneSession) = finished("Errand", estimate: 30, spent: 60, category: "Personal")

        let profile = LearningPass.build(tasks: workTasks + [oneTask],
                                         sessions: workSessions + [oneSession])
        #expect(profile.driftByCategory["Work"] == 1.5)
        #expect(profile.driftByCategory["Personal"] == nil)
        #expect(profile.finishedTaskSample == 9)
    }

    @Test("A correction made at capture is never applied a second time when planning")
    func noDoubleCounting() {
        var profile = LearnedProfile()
        profile.driftOverall = 1.4
        profile.finishedTaskSample = 12

        var task = TaskItem(title: "Enter REDCap data", effortMinutes: 85)
        task.metadata = LearnedEstimate.encode(original: 60, reason: "Your work runs about 40% long.")

        // 85 is already the corrected figure. Stretching it again would reserve 119 minutes for
        // an hour of work, and the error compounds every time the day is re-planned.
        #expect(profile.adjustment(for: task) == nil)
        #expect(profile.plannedMinutes(for: task) == 85)

        // An untouched task with the same estimate still gets corrected.
        let plain = TaskItem(title: "Something new", effortMinutes: 60)
        #expect(profile.plannedMinutes(for: plain) == 85)
    }

    @Test("Drift is measured against the first guess, not against its own correction")
    func driftAnchorsToTheRawEstimate() {
        // Five tasks that were captured at 60, corrected to 85, and really took 84. Measured
        // against the corrected figure this reads as ~1.0 — "estimates are fine now" — and the
        // correction would switch itself off, drift back out, and switch on again. Measured
        // against the 60 that was actually guessed, it stays the stable 1.4 it really is.
        var tasks: [TaskItem] = []
        var sessions: [TaskSession] = []
        for i in 0..<5 {
            var task = TaskItem(title: "Job \(i)", effortMinutes: 85)
            task.status = "completed"
            task.metadata = LearnedEstimate.encode(original: 60, reason: "because")
            tasks.append(task)
            sessions.append(TaskSession(taskId: task.id, category: nil,
                                        startedAt: "2026-07-29T09:00:00Z", endedAt: "2026-07-29T10:00:00Z",
                                        plannedMinutes: 25, actualMinutes: 84, ranToCompletion: true))
        }
        #expect(TaskSessionLog.drift(sessions: sessions, tasks: tasks) == 1.4)
    }

    @Test("An empty history concludes nothing")
    func emptyHistory() {
        let profile = LearningPass.build(tasks: [], sessions: [])
        #expect(profile.driftOverall == nil)
        #expect(profile.peakHours.isEmpty)
        #expect(profile.estimatePriors.isEmpty)
        #expect(profile.glossary.isEmpty)
    }
}

/// A note left on an adjusted task, so the change can be seen and undone.
struct LearnedEstimateTests {

    @Test("A note round-trips through metadata")
    func roundTrip() {
        let encoded = LearnedEstimate.encode(original: 60, reason: "Your Work runs about 40% long.")
        let note = LearnedEstimate.decode(encoded)
        #expect(note?.original == 60)
        #expect(note?.reason == "Your Work runs about 40% long.")
    }

    @Test("Writing a note never clobbers what's already in metadata")
    func preservesOtherKeys() {
        // A routine-materialised task carries its marker here. Losing it would orphan the task
        // from its routine.
        let existing = #"{"routineId":"r-1","routineDay":"2026-07-31"}"#
        let merged = LearnedEstimate.encode(original: 45, reason: "because", into: existing)
        #expect(merged?.contains("routineId") == true)
        #expect(LearnedEstimate.decode(merged)?.original == 45)

        let stripped = LearnedEstimate.removing(from: merged)
        #expect(stripped?.contains("routineId") == true)
        #expect(LearnedEstimate.decode(stripped) == nil)
    }

    @Test("Stripping the only keys leaves nothing rather than an empty object")
    func removingEverything() {
        let only = LearnedEstimate.encode(original: 30, reason: "because")
        #expect(LearnedEstimate.removing(from: only) == nil)
        #expect(LearnedEstimate.decode(nil) == nil)
        #expect(LearnedEstimate.decode("not json") == nil)
    }
}

/// Learning when the day actually works.
struct EnergyCurveTests {

    private func session(hour: Int, minutes: Int, day: Int = 20) -> TaskSession {
        let stamp = String(format: "2026-07-%02dT%02d:00:00Z", day, hour)
        return TaskSession(taskId: UUID().uuidString, category: nil,
                           startedAt: stamp, endedAt: stamp,
                           plannedMinutes: 25, actualMinutes: minutes, ranToCompletion: true)
    }

    @Test("Too little history means no curve at all")
    func needsASample() {
        let few = (0..<6).map { session(hour: 9, minutes: 50, day: 10 + $0) }
        #expect(EnergyCurve.learn(few).isConfident == false)
    }

    @Test("An hour is judged by how it goes, not by how often you're scheduled into it")
    func exposureNormalised() {
        // Twenty morning sittings you bail out of after five minutes, five middling afternoons,
        // and four evenings you stay ninety minutes for. By volume the morning wins in a landslide
        // — which is exactly the feedback loop to avoid, since the planner is what put you there.
        // Per sitting, the evening is plainly the good hour, and that's what should be learned.
        var sessions = (0..<20).map { session(hour: 9, minutes: 5, day: 1 + ($0 % 28)) }
        sessions += (0..<5).map { session(hour: 14, minutes: 20, day: 1 + $0) }
        sessions += (0..<4).map { session(hour: 20, minutes: 90, day: 1 + $0) }

        let curve = EnergyCurve.learn(sessions)
        #expect(curve.isConfident)
        #expect(curve.peak == [20])
        #expect(curve.scores[9]! < curve.scores[14]!)
    }

    @Test("An hour with only a session or two doesn't get scored")
    func hoursNeedTheirOwnEvidence() {
        var sessions = (0..<12).map { session(hour: 9, minutes: 45, day: 1 + $0) }
        sessions.append(session(hour: 3, minutes: 200))   // one heroic 3am
        let curve = EnergyCurve.learn(sessions)
        #expect(curve.scores[3] == nil)
        #expect(curve.scores[9] != nil)
    }

    @Test("A flat day produces no peak rather than an arbitrary one")
    func flatDayHasNoPeak() {
        // Every hour equally good. There's no answer here, and inventing one — "your peak is
        // 9am, 11am, 2pm and 4pm" — would be a confident reply to a question the data can't
        // settle, which is worse than saying nothing.
        var sessions: [TaskSession] = []
        for hour in [9, 11, 14, 16, 19] {
            sessions += (0..<3).map { session(hour: hour, minutes: 40, day: 1 + $0) }
        }
        let curve = EnergyCurve.learn(sessions)
        #expect(curve.scores.count == 5)
        #expect(curve.peak.isEmpty)
        #expect(curve.isConfident == false)
    }

    @Test("A single runaway sitting can't crown its hour")
    func medianNotMean() {
        var sessions = (0..<12).map { session(hour: 9, minutes: 50, day: 1 + $0) }
        // Three 14:00 sittings: two abandoned, one timer left running through the afternoon.
        // The mean would say 2pm is your best hour by far; the median says it isn't.
        sessions += [session(hour: 14, minutes: 4), session(hour: 14, minutes: 5),
                     session(hour: 14, minutes: 300)]
        let curve = EnergyCurve.learn(sessions)
        #expect((curve.scores[14] ?? 1) < (curve.scores[9] ?? 0))
    }
}

/// Learning what your own work takes.
struct EstimatePriorsTests {

    private func done(_ title: String, minutes: Int) -> (TaskItem, TaskSession) {
        var task = TaskItem(title: title, effortMinutes: 30)
        task.status = "completed"
        let session = TaskSession(taskId: task.id, category: nil,
                                  startedAt: "2026-07-29T09:00:00Z", endedAt: "2026-07-29T10:00:00Z",
                                  plannedMinutes: 25, actualMinutes: minutes, ranToCompletion: true)
        return (task, session)
    }

    @Test("Phrases collapse to what they're about, numbers and filler dropped")
    func keying() {
        // Filler and punctuation go; word order stops mattering.
        #expect(EstimatePriors.key("Review the cardio lecture!") == "cardio lecture review")
        #expect(EstimatePriors.key("cardio lecture review") == EstimatePriors.key("Review the cardio lecture"))
        // Numbers go too, so a dozen numbered lectures form one well-evidenced prior instead of
        // twelve useless ones. (The opposite of `ProjectMatcher`, where numbers are load-bearing:
        // "Jury 3" and "Jury 4" are different projects, but lecture 3 and lecture 4 take the same
        // hour to review.)
        #expect(EstimatePriors.key("Review lecture 4") == EstimatePriors.key("Review lecture 11"))
        #expect(EstimatePriors.key("the a of") == "")
    }

    @Test("A prior needs repetition before it's a prior")
    func needsRepetition() {
        var tasks: [TaskItem] = []
        var sessions: [TaskSession] = []
        for minutes in [50, 55] {
            let (t, s) = done("Review lecture", minutes: minutes)
            tasks.append(t); sessions.append(s)
        }
        #expect(EstimatePriors.learn(tasks: tasks, sessions: sessions).isEmpty)

        let (t, s) = done("Review lecture", minutes: 60)
        tasks.append(t); sessions.append(s)
        let priors = EstimatePriors.learn(tasks: tasks, sessions: sessions)
        #expect(priors.count == 1)
        #expect(priors[0].medianMinutes == 55)
        #expect(priors[0].sample == 3)
    }

    @Test("A new task finds the prior for work of the same kind")
    func matching() {
        let priors = [EstimatePrior(key: "lecture review", label: "Review lecture",
                                    medianMinutes: 52, sample: 14)]
        #expect(EstimatePriors.match("Review lecture 9", in: priors)?.medianMinutes == 52)
        #expect(EstimatePriors.match("review the cardio lecture", in: priors)?.medianMinutes == 52)
        // Unrelated work is left alone rather than forced into the nearest bucket.
        #expect(EstimatePriors.match("Email the PI", in: priors) == nil)
    }

    @Test("History only overrides the model when they genuinely disagree")
    func onlyMeaningfulOverrides() {
        let priors = [EstimatePrior(key: "lecture review", label: "Review lecture",
                                    medianMinutes: 52, sample: 14)]
        // 45 → 52 is not worth overriding a model for.
        #expect(EstimatePriors.suggestion(for: "Review lecture 3", modelEstimate: 45, priors: priors) == nil)
        // 20 → 52 is.
        let suggestion = EstimatePriors.suggestion(for: "Review lecture 3", modelEstimate: 20, priors: priors)
        #expect(suggestion?.minutes == 52)
        #expect(suggestion?.replaced == 20)
        #expect(suggestion?.reason == "You've done this 14 times — it takes you about 52m.")
        // No estimate at all: history is the only figure anyone has.
        #expect(EstimatePriors.suggestion(for: "Review lecture 3", modelEstimate: nil, priors: priors)?.minutes == 52)
    }
}

/// Learning the words you use.
struct GlossaryTests {

    private func tasks(_ titles: [String]) -> [TaskItem] {
        titles.map { TaskItem(title: $0) }
    }

    @Test("A term you use repeatedly is learned; a one-off isn't")
    func repetitionIsTheSignal() {
        let learned = Glossary.learn(tasks: tasks([
            "Enter REDCap data", "REDCap export", "Fix the REDCap form",
            "Buy oat milk"
        ]))
        #expect(learned.contains("REDCap"))
        #expect(learned.contains(where: { $0.lowercased() == "oat" }) == false)
    }

    @Test("Ordinary English doesn't become vocabulary through repetition alone")
    func commonWordsExcluded() {
        let learned = Glossary.learn(tasks: tasks([
            "Email the PI about it", "Email the lab", "Email the registrar", "Email admin"
        ]))
        #expect(learned.contains("Email") == false)
        #expect(learned.contains("email") == false)
    }

    @Test("The casing you actually use is kept — it's half the signal")
    func keepsCasing() {
        let learned = Glossary.learn(tasks: tasks([
            "REDCap import", "REDCap export", "REDCap cleanup"
        ]))
        #expect(learned.first == "REDCap")
    }

    @Test("Nothing learned means nothing added to the prompt")
    func emptyFragment() {
        #expect(Glossary.promptFragment([]) == nil)
        let fragment = Glossary.promptFragment(["REDCap", "OSCE"])
        #expect(fragment?.contains("REDCap") == true)
        #expect(fragment?.contains("never split") == true)
    }
}

/// Catching a thought you've already had.
struct TaskMatcherTests {

    @Test("The same sentence said twice is caught")
    func exactRestatement() {
        let existing = [TaskItem(title: "Email the PI about the abstract")]
        let match = TaskMatcher.duplicate(of: "email the PI about the abstract", among: existing)
        #expect(match?.confidence == .exact)
    }

    @Test("A typo is still the same thought")
    func nearMiss() {
        let existing = [TaskItem(title: "Enter REDCap data")]
        #expect(TaskMatcher.duplicate(of: "Enter REDCap dat", among: existing)?.confidence == .close)
    }

    @Test("Different numbers are never the same task, however close the words")
    func numbersMustAgree() {
        let existing = [TaskItem(title: "Review lecture 4")]
        #expect(TaskMatcher.duplicate(of: "Review lecture 5", among: existing) == nil)
    }

    @Test("Finished work is history — saying it again means doing it again")
    func completedTasksAreNotDuplicates() {
        var done = TaskItem(title: "Water the plants")
        done.status = "completed"
        #expect(TaskMatcher.duplicate(of: "Water the plants", among: [done]) == nil)
    }

    @Test("A stated time is a commitment, never a duplicate")
    func timedTasksAlwaysSurvive() {
        let existing = [TaskItem(title: "Call the clinic")]
        var timed = TaskItem(title: "Call the clinic", dueDate: "2026-08-01T15:00:00Z")
        timed.dueIsAllDay = false

        let result = TaskMatcher.partition(newTasks: [timed], existing: existing)
        #expect(result.create.count == 1)
        #expect(result.duplicates.isEmpty)
    }

    @Test("Steps of a dropped duplicate are re-pointed at the task that survived")
    func stepsFollowTheSurvivor() {
        let existing = TaskItem(title: "Enter REDCap data")
        let restated = TaskItem(title: "Enter REDCap data")
        var step = TaskItem(title: "Pull the export")
        step.parentTaskId = restated.id

        let result = TaskMatcher.partition(newTasks: [restated, step], existing: [existing])
        #expect(result.duplicates.count == 1)
        // The step survives — it's new detail — but attached to the task you already had, rather
        // than orphaned onto a parent that was never created.
        #expect(result.create.map(\.title) == ["Pull the export"])
        #expect(result.create[0].parentTaskId == existing.id)
    }

    @Test("The same thing said twice in one breath collapses too")
    func duplicatesWithinOneCapture() {
        let result = TaskMatcher.partition(
            newTasks: [TaskItem(title: "Book the flight"), TaskItem(title: "book the flight")],
            existing: [])
        #expect(result.create.count == 1)
        #expect(result.duplicates.count == 1)
    }
}

/// How previous plans actually went.
struct PlanOutcomesTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ hour: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func iso(_ hour: Int, day: Int) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: at(hour, day: day))
    }

    /// A block scheduled at `hour` on `day`, optionally finished on the day it was planned.
    private func block(_ title: String, hour: Int, day: Int, done: Bool, minutes: Int = 30) -> TaskItem {
        var task = TaskItem(title: title, dueDate: iso(hour, day: day), effortMinutes: minutes)
        task.dueIsAllDay = false
        if done {
            task.status = "completed"
            task.completedAt = iso(hour + 1, day: day)
        }
        return task
    }

    @Test("Only blocks that have already had their chance are scored")
    func onlyPastBlocks() {
        let today = at(12, day: 20)
        let tasks = [
            block("Past, done", hour: 9, day: 18, done: true),
            block("Past, missed", hour: 9, day: 19, done: false),
            block("Still ahead", hour: 18, day: 20, done: false),      // hasn't happened yet
            TaskItem(title: "Whole-day thing", dueDate: iso(9, day: 18))  // never had a time
        ]
        var wholeDay = tasks[3]
        wholeDay.dueIsAllDay = true

        let summary = PlanOutcomes.summarize(tasks: Array(tasks.prefix(3)) + [wholeDay],
                                             now: today, calendar: calendar)
        #expect(summary.overall.planned == 2)
        #expect(summary.overall.done == 1)
        #expect(summary.overall.percent == 50)
    }

    @Test("Finishing Tuesday's block on Thursday is not the plan working")
    func doneMeansDoneThatDay() {
        var late = block("Late", hour: 9, day: 18, done: false)
        late.status = "completed"
        late.completedAt = iso(9, day: 19)      // a day after it was scheduled

        let summary = PlanOutcomes.summarize(tasks: [late], now: at(12, day: 20), calendar: calendar)
        #expect(summary.overall.planned == 1)
        #expect(summary.overall.done == 0)
    }

    @Test("A thin history says nothing at all")
    func staysQuietUntilItKnowsSomething() {
        let tasks = (1...4).map { block("Job \($0)", hour: 9, day: 10 + $0, done: true) }
        let summary = PlanOutcomes.summarize(tasks: tasks, now: at(12, day: 20), calendar: calendar)
        #expect(summary.isMeaningful == false)
        #expect(PlanOutcomes.promptFragment(summary) == nil)
        #expect(PlanOutcomes.observations(summary).isEmpty)
    }

    @Test("Time-of-day rates are reported once there's evidence for them")
    func timeOfDaySplit() {
        var tasks: [TaskItem] = []
        // Six morning blocks, all done; six evening blocks, none done.
        for day in 10...15 { tasks.append(block("AM \(day)", hour: 8, day: day, done: true)) }
        for day in 10...15 { tasks.append(block("PM \(day)", hour: 20, day: day, done: false)) }

        let summary = PlanOutcomes.summarize(tasks: tasks, now: at(12, day: 20), calendar: calendar)
        #expect(summary.overall.percent == 50)
        let morning = summary.byTimeOfDay.first { $0.label == "before 10am" }
        let evening = summary.byTimeOfDay.first { $0.label == "evening" }
        #expect(morning?.percent == 100)
        #expect(evening?.percent == 0)

        let fragment = PlanOutcomes.promptFragment(summary)
        #expect(fragment?.contains("before 10am") == true)
        #expect(fragment?.contains("Weigh this against deadlines") == true)
        #expect(PlanOutcomes.observations(summary).contains { $0.contains("100%") })
    }

    @Test("Long blocks are scored separately from short ones")
    func blockLength() {
        var tasks: [TaskItem] = []
        for day in 10...14 { tasks.append(block("Long \(day)", hour: 9, day: day, done: false, minutes: 120)) }
        for day in 10...14 { tasks.append(block("Short \(day)", hour: 9, day: day, done: true, minutes: 30)) }

        let summary = PlanOutcomes.summarize(tasks: tasks, now: at(12, day: 20), calendar: calendar)
        let long = summary.byLength.first { $0.label.hasPrefix("blocks over") }
        let short = summary.byLength.first { $0.label == "shorter blocks" }
        #expect(long?.percent == 0)
        #expect(short?.percent == 100)
        #expect(PlanOutcomes.observations(summary).contains { $0.contains("worth splitting") })
    }
}
