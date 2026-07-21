import Foundation

/// The AI-reasoned day plan.
///
/// The deterministic `DayPlanner` is excellent at the *geometry* — fitting work into the real
/// gaps around your commitments without overlaps or overruns. What it can't do is *judge*:
/// that the assignment due Friday matters more than the one due next week even though both are
/// "medium", that you should knock out the quick email before the deep work, that reviewing
/// notes right before class beats doing it this morning.
///
/// So this asks Gemini to rank the day's flexible work given everything — deadlines, what's
/// fixed, your energy peak, how the pieces relate — then feeds that order into the tested placer.
/// The LLM decides *sequence*; the deterministic engine still owns the *times*, so it can never
/// double-book or hallucinate a slot. Falls back to the deterministic order when the cloud
/// isn't available.
@MainActor
enum SmartPlanner {

    struct Result {
        var plan: DayPlanner.Plan
        /// The AI's one-line reasoning, when it ran. Shown to the user so the plan feels
        /// considered, not arbitrary.
        var rationale: String?
        var usedAI: Bool
    }

    private struct Ranking: Codable {
        var order: [Int]        // 1-based indices into the numbered task list we sent
        var rationale: String?
    }

    static func plan(
        tasks: [TaskItem],
        events: [CalendarEvent],
        on day: Date,
        now: Date,
        dayStartHour: Int,
        dayEndHour: Int,
        energyProfile: EnergyProfile?,
        calendar: Calendar = .current
    ) async -> Result {
        let candidates = DayPlanner.candidates(from: tasks, on: day, now: now, calendar: calendar)

        // Only worth a call when there's a real ordering decision to make.
        var order: [String]?
        var rationale: String?
        var usedAI = false
        if candidates.count >= 2 {
            if let ranking = await rank(candidates: candidates, events: events, tasks: tasks,
                                        day: day, now: now, energyProfile: energyProfile, calendar: calendar) {
                order = ranking.order.compactMap { idx in
                    candidates.indices.contains(idx - 1) ? candidates[idx - 1].id : nil
                }
                rationale = ranking.rationale
                usedAI = true
            }
        }

        let plan = DayPlanner.plan(
            tasks: tasks, events: events, on: day, now: now,
            dayStartHour: dayStartHour, dayEndHour: dayEndHour,
            energyProfile: energyProfile, preferredOrder: order
        )
        return Result(plan: plan, rationale: rationale, usedAI: usedAI)
    }

    // MARK: The AI call

    private static func rank(
        candidates: [TaskItem], events: [CalendarEvent], tasks: [TaskItem],
        day: Date, now: Date, energyProfile: EnergyProfile?, calendar: Calendar
    ) async -> Ranking? {
        await AIRouter.shared.run(label: "plan") { key in
            let client = GeminiClient(apiKey: key)
            let schema: GSchema = .object(properties: [
                ("order", .array(.integer())),
                ("rationale", .string(nullable: true))
            ], required: ["order"])
            return try await client.generate(
                system: systemPrompt(now: now, energyProfile: energyProfile),
                prompt: userPrompt(candidates: candidates, events: events, tasks: tasks, day: day, calendar: calendar),
                schema: schema, as: Ranking.self, temperature: 0.3
            )
        }
    }

    static func systemPrompt(now: Date, energyProfile: EnergyProfile?) -> String {
        let energy = energyProfile.map { "The person works best in the \($0.rawValue)." } ?? ""
        return """
        You order a person's flexible tasks for today into the sequence they should tackle them,
        given their fixed commitments, deadlines, energy, and how the tasks relate. \(energy)
        Return `order`: the task numbers, best-first. Put genuinely urgent or deadline-driven work
        early, group related tasks, place demanding work in their peak hours and light admin in
        the troughs, and prefer a quick win early to build momentum. Include EVERY task number
        exactly once. Add a short, warm one-sentence `rationale` explaining the shape of the plan
        ("Front-loaded the report before your 2pm class, saved email for the afternoon lull").
        The current time is \(ISO8601DateFormatter().string(from: now)).
        """
    }

    static func userPrompt(candidates: [TaskItem], events: [CalendarEvent], tasks: [TaskItem],
                           day: Date, calendar: Calendar) -> String {
        var lines = ["Fixed today (do not reorder — context only):"]
        let fixed = DayPlanner.fixedCommitments(from: tasks, on: day, calendar: calendar)
        let timedEvents = events.filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: day) }
        if fixed.isEmpty && timedEvents.isEmpty {
            lines.append("- (nothing fixed)")
        } else {
            for e in timedEvents.sorted(by: { $0.start < $1.start }) {
                lines.append("- \(timeLabel(e.start)) \(e.title)")
            }
            for t in fixed.sorted(by: { ($0.dueDate ?? "") < ($1.dueDate ?? "") }) {
                let time = DueDate.parse(t.dueDate).map(timeLabel) ?? "sometime"
                lines.append("- \(time) \(t.title)")
            }
        }

        lines.append("\nFlexible tasks to order:")
        for (i, task) in candidates.enumerated() {
            var parts = ["\(i + 1). \(task.title)"]
            parts.append("priority \(task.priority)")
            if let e = task.effortMinutes { parts.append("~\(e)m") }
            if let d = DueDate.parse(task.deadline) { parts.append("deadline \(dayLabel(d))") }
            if let cat = task.category { parts.append(cat) }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func timeLabel(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "h:mma"; return df.string(from: date)
    }
    private static func dayLabel(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE MMM d"; return df.string(from: date)
    }
}
