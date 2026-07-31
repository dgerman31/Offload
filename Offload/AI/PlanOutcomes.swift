import Foundation

/// How previous plans actually went, so the next one is made by something that remembers.
///
/// `SmartPlanner` has been ordering days with no feedback of any kind. It never found out that
/// this person finishes almost everything they schedule before ten and almost nothing they
/// schedule after eight, or that their two-hour blocks are aspirational and their forty-minute
/// ones are real. It made the same shape of plan every day and was told nothing when the day
/// disagreed.
///
/// ### What can honestly be known
///
/// A task's `dueDate` is *current*, not historical — when work rolls to tomorrow, the record of it
/// having been planned for today is overwritten. So this can't reconstruct old plans. What it can
/// see is unambiguous: a task scheduled for a past time either got completed or it didn't. Work
/// that rolled forward has a future date and drops out of the window entirely, which means these
/// rates **understate** failure and never invent it. That's the right direction for a number that
/// feeds a prompt — it can only ever be too kind.
enum PlanOutcomes {

    /// Three weeks: long enough for a rate to mean something, short enough that a term that
    /// changed shape a month ago isn't still being cited.
    static let windowDays = 21
    /// Below this many scheduled blocks, a percentage is theatre.
    static let minimumSample = 8
    /// A bucket needs its own evidence before it gets its own sentence.
    static let minimumBucketSample = 4
    /// Where "a long block" starts. Ninety minutes is about where a single sitting stops being one.
    static let longBlockMinutes = 90

    struct Bucket: Equatable, Sendable {
        var label: String
        var planned: Int
        var done: Int
        var rate: Double { planned == 0 ? 0 : Double(done) / Double(planned) }
        var percent: Int { Int((rate * 100).rounded()) }
        var isMeaningful: Bool { planned >= PlanOutcomes.minimumBucketSample }
    }

    struct Summary: Equatable, Sendable {
        var overall = Bucket(label: "overall", planned: 0, done: 0)
        var byTimeOfDay: [Bucket] = []
        var byLength: [Bucket] = []
        var isMeaningful: Bool { overall.planned >= PlanOutcomes.minimumSample }
    }

    /// Score every block that has already had its chance.
    static func summarize(
        tasks: [TaskItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = windowDays
    ) -> Summary {
        var summary = Summary()
        guard let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) else { return summary }

        let steps = DayPlanner.stepIds(in: tasks)
        var timeOfDay: [String: (planned: Int, done: Int)] = [:]
        var length: [String: (planned: Int, done: Int)] = [:]

        for task in tasks where !task.deleted && !steps.contains(task.id) {
            // A whole-day intention was never scheduled *at* a time, so it can't speak to whether
            // times work. Only real blocks count.
            guard !task.dueIsAllDay, let planned = DueDate.parse(task.dueDate),
                  planned >= cutoff, planned < now else { continue }

            // Done means done that day. Finishing Tuesday's block on Thursday is not the plan
            // working; it's the plan having been wrong and you having rescued it.
            let done: Bool = {
                guard task.status == "completed", let at = DueDate.parse(task.completedAt) else { return false }
                return calendar.isDate(at, inSameDayAs: planned)
            }()

            summary.overall.planned += 1
            if done { summary.overall.done += 1 }

            let slot = timeOfDayLabel(planned, calendar: calendar)
            timeOfDay[slot, default: (0, 0)].planned += 1
            if done { timeOfDay[slot, default: (0, 0)].done += 1 }

            let size = (task.effortMinutes ?? EnergyBatch.defaultEffort) >= longBlockMinutes
                ? "blocks over \(longBlockMinutes / 60)h"
                : "shorter blocks"
            length[size, default: (0, 0)].planned += 1
            if done { length[size, default: (0, 0)].done += 1 }
        }

        summary.byTimeOfDay = timeOfDayOrder
            .compactMap { label in
                timeOfDay[label].map { Bucket(label: label, planned: $0.planned, done: $0.done) }
            }
            .filter(\.isMeaningful)
        summary.byLength = length
            .map { Bucket(label: $0.key, planned: $0.value.planned, done: $0.value.done) }
            .filter(\.isMeaningful)
            .sorted { $0.label < $1.label }
        return summary
    }

    static let timeOfDayOrder = ["before 10am", "late morning", "afternoon", "evening"]

    static func timeOfDayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case ..<10:  return "before 10am"
        case 10..<12: return "late morning"
        case 12..<17: return "afternoon"
        default:      return "evening"
        }
    }

    /// What the planner gets told about itself. `nil` until there's enough history, so a new
    /// user's prompt isn't padded with statistics about eleven blocks.
    ///
    /// Deliberately facts, not instructions: "evening blocks get done 24% of the time" lets the
    /// model weigh that against a genuine evening deadline. "Never schedule evenings" would not.
    static func promptFragment(_ summary: Summary) -> String? {
        guard summary.isMeaningful else { return nil }
        var lines = ["HOW THIS PERSON'S RECENT PLANS ACTUALLY WENT (last \(windowDays) days, \(summary.overall.planned) scheduled blocks):"]
        lines.append("- Overall, \(summary.overall.percent)% of scheduled blocks got done on the day.")
        for bucket in summary.byTimeOfDay {
            lines.append("- Scheduled \(bucket.label): \(bucket.percent)% done (\(bucket.planned) blocks).")
        }
        for bucket in summary.byLength {
            lines.append("- \(bucket.label.prefix(1).uppercased() + bucket.label.dropFirst()): \(bucket.percent)% done (\(bucket.planned) blocks).")
        }
        lines.append("Weigh this against deadlines rather than obeying it — a slot that usually fails is a reason to hesitate, not a rule.")
        return lines.joined(separator: "\n")
    }

    /// The same finding, said to the user on the learned screen.
    static func observations(_ summary: Summary) -> [String] {
        guard summary.isMeaningful else { return [] }
        var lines = ["\(summary.overall.percent)% of what you schedule gets done on the day."]

        let ranked = summary.byTimeOfDay.sorted { $0.rate > $1.rate }
        if let best = ranked.first, let worst = ranked.last, best.label != worst.label,
           best.percent - worst.percent >= 20 {
            lines.append("Work you put \(best.label) gets done \(best.percent)% of the time. \(worst.label.prefix(1).uppercased() + worst.label.dropFirst()): \(worst.percent)%.")
        }
        if summary.byLength.count == 2 {
            let long = summary.byLength.first { $0.label.hasPrefix("blocks over") }
            let short = summary.byLength.first { $0.label == "shorter blocks" }
            if let long, let short, short.percent - long.percent >= 20 {
                lines.append("Your long blocks finish \(long.percent)% of the time against \(short.percent)% for short ones — worth splitting them.")
            }
        }
        return lines
    }
}
