import AppIntents
import GRDB

/// "Hey Siri, what's on my plate?"
///
/// Capture solved getting thoughts *in*; this is the other half — getting an answer *out*
/// without unlocking, opening the app and reading a screen. Ask while you're driving, cooking,
/// or walking out the door, and Siri tells you what actually matters right now.
///
/// Answered from the local database, spoken aloud, no app launch.
struct DailyBriefIntent: AppIntent {
    static let title: LocalizedStringResource = "What's on my plate"
    static let description = IntentDescription("Hear what needs you today without opening the app.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let db = AppDatabase.shared
        let tasks = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []

        let events = await EventKitCalendarReader().events(
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        )

        let summary = DayDashboard.summary(tasks: tasks, events: events, now: Date())
        return .result(dialog: IntentDialog(stringLiteral: Self.spokenBrief(summary)))
    }

    /// Written to be *heard*, not read: leads with the single most useful fact and names the
    /// next actual thing rather than reciting counts.
    static func spokenBrief(_ summary: DaySummary) -> String {
        var parts: [String] = []

        if summary.overdueCount > 0 {
            parts.append("You have \(summary.overdueCount) overdue task\(summary.overdueCount == 1 ? "" : "s")")
        }
        if summary.dueTodayCount > 0 {
            parts.append("\(summary.dueTodayCount) due today")
        }
        if summary.eventCount > 0 {
            parts.append("and \(summary.eventCount) thing\(summary.eventCount == 1 ? "" : "s") on your calendar")
        }

        if parts.isEmpty {
            return summary.completedToday > 0
                ? "Nothing left today. You've already finished \(summary.completedToday)."
                : "Nothing needs you right now."
        }

        var line = parts.joined(separator: ", ") + "."
        if let next = summary.nextEvent, !next.isAllDay {
            line += " Next up is \(next.title) at \(CalendarView.time(next.start))."
        } else if let task = summary.nextTask {
            line += " The best thing to start is \(task.title)."
        }
        return line
    }
}

/// "Hey Siri, what do I owe Sarah?" — the obligations that nag hardest, answered hands-free.
struct CommitmentsIntent: AppIntent {
    static let title: LocalizedStringResource = "What do I owe someone"
    static let description = IntentDescription("Hear what's outstanding with a particular person.")

    @Parameter(title: "Person", requestValueDialog: "Who?")
    var person: String

    static var parameterSummary: some ParameterSummary {
        Summary("What do I owe \(\.$person)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let db = AppDatabase.shared
        let tasks = (try? await db.dbQueue.read { database in
            try TaskItem.filter(Column("deleted") == false).fetchAll(database)
        }) ?? []

        let commitments = People.commitments(from: tasks, now: Date())
        let needle = person.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let match = commitments.first(where: { $0.name.lowercased().contains(needle) }) else {
            return .result(dialog: "Nothing outstanding with \(person).")
        }
        return .result(dialog: IntentDialog(stringLiteral: Self.spokenCommitments(match)))
    }

    static func spokenCommitments(_ commitment: People.Commitment) -> String {
        let titles = commitment.open.prefix(3).map(\.title)
        guard !titles.isEmpty else { return "Nothing outstanding with \(commitment.name)." }

        let list = titles.count == 1
            ? titles[0]
            : titles.dropLast().joined(separator: ", ") + ", and " + (titles.last ?? "")

        var line = "You owe \(commitment.name): \(list)."
        if commitment.open.count > titles.count {
            line += " Plus \(commitment.open.count - titles.count) more."
        }
        return line
    }
}
