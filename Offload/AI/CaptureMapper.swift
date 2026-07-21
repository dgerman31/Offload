import Foundation

/// Converts the model's `ExtractedCapture` into domain records ready for SQLite.
/// Pure and deterministic — no model calls — so it's fully unit-testable.
enum CaptureMapper {

    /// The valid category set (spec §4, feature 3). Anything off-list falls back to "Other".
    static let categories: Set<String> = [
        "Work", "Personal", "Health", "Finance", "Projects", "Ideas", "Habits", "Other"
    ]
    static let priorities: Set<String> = ["high", "medium", "low"]

    /// The fixed context-tag vocabulary — anything the model invents outside this is dropped.
    static let allowedContextTags: Set<String> = [
        "home", "work", "car", "outside", "store", "gym", "phone", "computer", "meeting", "errands"
    ]

    /// Minimum tasks before a capture is allowed to become a project — keeps single
    /// everyday tasks from being over-organized into projects (user feedback).
    static let minTasksForProject = 2

    struct Result {
        var project: Project?
        var tasks: [TaskItem]
        /// Ids of tasks the model classified as real calendar appointments *and* that carry a
        /// due date — the ones the capture pipeline turns into EventKit events (spec §3.3 write).
        var appointmentTaskIds: Set<String> = []
    }

    /// Build a `Project` (only for genuine multi-step clusters) and the `TaskItem`s, linked to it.
    /// `now` grounds the due-date priority guardrail; `sourceText` (the raw capture) grounds the
    /// invented-effort guard. Both defaulted so callers stay simple.
    static func map(
        _ extracted: ExtractedCapture,
        now: Date = Date(),
        calendar: Calendar = .current,
        sourceText: String? = nil
    ) -> Result {
        // The model invents effort estimates freely (a bare "Launch app" coming back as 180m).
        // Only trust one when the capture itself carried a duration signal.
        let trustEffort = sourceText.map(hasDurationSignal) ?? true
        // Likewise for dates: with no temporal language in the capture there is nothing to
        // resolve, so any date the model returns is invention — and at 12:48 AM that
        // invention becomes a task due at 1 AM.
        let trustDates = sourceText.map(hasTemporalSignal) ?? true

        // Is the user talking TO the app ("create a project called X" — a command) or ABOUT
        // their work ("I need to create a project" — a to-do)? The former makes a container;
        // the latter is a task.
        let containerCommand = sourceText.map(isContainerCommand) ?? false

        let projectName: String? = {
            if let name = extracted.suggestedProject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty { return name }
            // An explicit command whose name the model failed to pull out — recover it from
            // the words themselves ("...called X").
            if containerCommand { return sourceText.flatMap { containerName(from: $0) } }
            return nil
        }()

        let project: Project? = {
            guard let name = projectName, !name.isEmpty else { return nil }
            // An explicit "create a project" command makes the container even with no other
            // tasks; otherwise require a genuine multi-task cluster so a single errand isn't
            // over-organized into a project.
            guard containerCommand || extracted.tasks.count >= minTasksForProject else { return nil }
            return Project(title: name)
        }()

        var tasks: [TaskItem] = []
        var appointmentTaskIds: Set<String> = []
        for t in extracted.tasks {
            // When the user commanded "create a project", the creation IS the action — drop any
            // redundant "Create project X" task the model tacked on.
            if containerCommand, isCreateContainerTask(t.title) { continue }
            let resolved = resolveDue(t.dueDate, trustDates: trustDates, calendar: calendar)
            let dueDate = resolved.value
            let isAllDay = resolved.isAllDay
            let cleanTitle = actionTitle(t.title)
            // A real appointment is a genuine commitment — it anchors the day. A time the model
            // merely guessed stays soft so the self-healing timeline can reflow it.
            let appointment = isRealAppointment(title: cleanTitle, isAppointment: t.isAppointment,
                                                dueDate: dueDate, isAllDay: isAllDay)
            let parent = TaskItem(
                title: cleanTitle,
                descriptionText: nonEmpty(t.details),
                category: normalizedCategory(t.category),
                priority: resolvedPriority(normalizedPriority(t.priority), dueDate: dueDate, now: now, calendar: calendar),
                projectId: project?.id,
                dueDate: dueDate,
                dueDateConfidence: dueDate == nil ? nil : 0.5,
                recurrenceRule: nonEmpty(t.recurrenceRule),
                contextTags: encodeTags(t.contextTags),
                effortMinutes: trustEffort ? t.effortMinutes : nil,
                people: People.encode(t.people),
                deadline: trustDates ? DueDate.normalizeLocal(t.deadline, timeZone: calendar.timeZone) : nil,
                dueIsAllDay: isAllDay,
                pinned: appointment
            )
            tasks.append(parent)
            // Writing to someone's real calendar needs more than the model's say-so: a genuine
            // time, and a title that isn't itself about *arranging* the thing.
            if isRealAppointment(title: parent.title, isAppointment: t.isAppointment,
                                 dueDate: dueDate, isAllDay: isAllDay) {
                appointmentTaskIds.insert(parent.id)
            }

            // Hierarchical extraction (spec feature 1), but restrained (punch list #4): sub-steps
            // become child tasks only when there are ≥2 genuinely distinct steps that don't just
            // restate the errand. They inherit the parent's category/priority/context. Cleaning
            // titles BEFORE the restraint pass lets fluff-only variants collapse as duplicates.
            for title in restrainedSubtasks(parentTitle: parent.title, subtasks: t.subtasks.map(actionTitle)) {
                tasks.append(TaskItem(
                    title: title,
                    category: parent.category,
                    priority: parent.priority,
                    parentTaskId: parent.id,
                    projectId: project?.id,
                    contextTags: parent.contextTags
                ))
            }
        }
        return Result(project: project, tasks: tasks, appointmentTaskIds: appointmentTaskIds)
    }

    /// Guard against over-decomposition (punch list #4). Keeps subtasks ONLY when there are at
    /// least two genuinely distinct sub-steps, dropping any that merely restate the parent
    /// errand (e.g. parent "Buy milk" with a subtask "Buy milk", or "Go to the store to buy
    /// milk" with a subtask "Buy milk"). Fewer than two distinct steps → the task stands alone.
    static func restrainedSubtasks(parentTitle: String, subtasks: [String]) -> [String] {
        let parent = normalizedForComparison(parentTitle)
        var seen = Set<String>()
        var kept: [String] = []
        for raw in subtasks {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let norm = normalizedForComparison(title)
            guard !norm.isEmpty else { continue }
            // Drop anything that restates the parent errand (either direction).
            if norm == parent || (!parent.isEmpty && (parent.contains(norm) || norm.contains(parent))) { continue }
            guard seen.insert(norm).inserted else { continue }   // collapse duplicates
            kept.append(title)
        }
        return kept.count >= 2 ? kept : []
    }

    /// Lowercased, alphanumerics-and-spaces-only, whitespace-collapsed form for the restraint
    /// comparison above — so punctuation and casing don't hide a restatement.
    private static func normalizedForComparison(_ s: String) -> String {
        let cleaned = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // MARK: Helpers

    /// Accept the built-in set plus anything the user has defined for themselves; anything
    /// else the model invents still falls back to "Other".
    static func normalizedCategory(_ raw: String, allowed: [String]? = nil) -> String {
        let valid = allowed ?? CustomCategories.all()
        if let match = valid.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return match
        }
        return categories.contains(raw) ? raw : "Other"
    }

    static func normalizedPriority(_ raw: String) -> String {
        priorities.contains(raw) ? raw : "medium"
    }

    /// Deterministic backstop behind the intent-extraction prompt: a stored title never keeps
    /// the user's meta-frame even when the model parrots it. Strips stacked fluff prefixes
    /// ("remember to", "need to", "try to", …), then capitalizes the first letter so titles
    /// read as clean action phrases. Falls back to the trimmed original rather than ever
    /// producing an empty title.
    static func actionTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fluff = [
            "remember to ", "don't forget to ", "dont forget to ", "make sure to ",
            "i need to ", "i have to ", "i gotta ", "i should ", "i want to ",
            "need to ", "have to ", "gotta ", "try to "
        ]
        var title = trimmed
        var stripped = true
        while stripped {
            stripped = false
            for prefix in fluff where title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        guard !title.isEmpty else { return trimmed }
        if let first = title.first, first.isLowercase {
            title = String(first).uppercased() + title.dropFirst()
        }
        return title
    }

    /// Decide what a model-supplied due date actually means.
    ///
    /// Three outcomes: dropped entirely (the capture never mentioned time), kept as a
    /// whole-day intention (a date with no meaningful hour, or an hour nobody works), or kept
    /// as a real moment. The middle case is the important one — "Friday" should stay Friday
    /// rather than becoming Friday at midnight.
    static func resolveDue(
        _ raw: String?,
        trustDates: Bool,
        calendar: Calendar = .current
    ) -> (value: String?, isAllDay: Bool) {
        // Local-first: the model means the user's wall clock, not UTC. Use the calendar's zone
        // so this is deterministic in tests and correct in the user's real timezone.
        guard trustDates, let parsed = DueDate.parseLocal(raw, timeZone: calendar.timeZone)
        else { return (nil, false) }

        // Midnight almost always means "that day", not "at 00:00".
        let components = calendar.dateComponents([.hour, .minute], from: parsed)
        let looksDayOnly = (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0

        // A time in the small hours is a resolution artefact, not an intention.
        if looksDayOnly || isSleepingHour(parsed, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: parsed)
            return (DueDate.canonicalString(from: dayStart), true)
        }
        return (DueDate.canonicalString(from: parsed), false)
    }

    // MARK: Command vs. to-do

    /// Nouns that name a container the app can make.
    private static let containerNouns = ["project", "list", "folder", "category"]
    /// Verbs that create one.
    private static let makeVerbs = ["create", "make", "add", "start", "set up", "setup", "new"]

    /// Is the capture a direct instruction TO the app to create a container, rather than the
    /// user describing something they need to do?
    ///
    /// The distinction is grammatical: a command leads with the verb ("create a project called
    /// X"), while a to-do names a subject first ("I need to create a project"). Because a to-do
    /// starts with "I" / "we" / a modal, anchoring the match to the start of the sentence
    /// cleanly separates the two — "I need to create a project" simply doesn't match.
    static func isContainerCommand(_ text: String) -> Bool {
        var lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip polite lead-ins that are still aimed at the app.
        for lead in ["please ", "can you ", "could you ", "hey ", "ok ", "okay ", "just "] {
            if lower.hasPrefix(lead) { lower = String(lower.dropFirst(lead.count)) }
        }
        let verbs = makeVerbs.joined(separator: "|")   // "set up" keeps its space — fine in a regex
        let nouns = containerNouns.joined(separator: "|")
        let pattern = "^(\(verbs))\\s+(a\\s+|an\\s+|the\\s+)?(new\\s+)?(\(nouns))\\b"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    /// Does a task title just restate "create the container"? Such a task is redundant once the
    /// container itself is being made.
    static func isCreateContainerTask(_ title: String) -> Bool {
        let lower = title.lowercased()
        return makeVerbs.contains { lower.hasPrefix($0) } && containerNouns.contains { lower.contains($0) }
    }

    /// Pull a container's name out of the raw command ("...called X", "...named X"), stopping
    /// at the first clause boundary so trailing tasks don't get swept into the title.
    static func containerName(from text: String) -> String? {
        let lower = text
        for marker in [" called ", " named ", " titled ", " for "] {
            guard let r = lower.range(of: marker, options: .caseInsensitive) else { continue }
            var rest = String(lower[r.upperBound...])
            if let cut = rest.range(of: #"[,.;:]|\band\b|\bthen\b|\bi need\b|\bi have\b|\bi want\b|\bi gotta\b|\bi should\b"#,
                                    options: [.regularExpression, .caseInsensitive]) {
                rest = String(rest[..<cut.lowerBound])
            }
            let name = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 60 else { continue }
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return nil
    }

    /// Words that indicate the user actually said *when*. Deliberately broad on days and
    /// deliberately narrow on anything that could be a coincidence.
    /// Matched on word boundaries, never as substrings — a bare "am" happily appears inside
    /// "tambe", "name" and "example", which is exactly how a research note became a 1 AM task.
    /// Bare am/pm are therefore handled only by the digit pattern below ("3pm", "9 am").
    private static let dateWords = [
        "today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening", "night",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "week", "weekend", "weekday", "month", "year", "deadline", "due", "by", "before",
        "after", "asap", "urgent", "now", "later", "soon", "next", "every", "daily",
        "weekly", "monthly", "annually", "noon", "midnight", "oclock",
        "birthday", "anniversary", "appointment", "eod", "eow"
    ]

    /// Did the capture actually mention *when*? This is the guard that stops a thought typed
    /// at 12:48 AM from becoming a task due at 1:00 AM: with no temporal language at all, the
    /// model has nothing to resolve, so any date it produces is invention.
    static func hasTemporalSignal(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "o'clock", with: "oclock")

        // A number that reads as a time or a date: "3pm", "9 am", "14:30", "5/12", "the 14th".
        if lower.range(of: #"\d{1,2}\s*(:\d|am\b|pm\b|st\b|nd\b|rd\b|th\b|/|-)"#,
                       options: .regularExpression) != nil {
            return true
        }

        // Whole words only.
        let pattern = "\\b(" + dateWords.joined(separator: "|") + ")\\b"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    /// Hours nobody means to be working. A derived time landing here is a bug, not a plan.
    static let sleepingHours = 22..<7

    static func isSleepingHour(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }

    /// Did the capture actually say anything about how long something takes? Digits cover
    /// "20 min"/"a 2 hour block"; the word list covers spoken durations. Deliberately narrow —
    /// timing words like "tomorrow" say WHEN, not HOW LONG, so they don't count.
    static func hasDurationSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        let durationWords = [
            "minute", "min ", "mins", "hour", "hr", "hrs", "quick", "quickly", "brief",
            "a while", "long time", "all day", "half day", "takes"
        ]
        return durationWords.contains { lower.contains($0) }
    }

    /// Verbs that mean "arrange this" rather than "this is arranged". A task whose whole
    /// point is *to book a thing* has no time yet, so it must never become a calendar event —
    /// "Schedule a meeting with Dr. Bannazadeh" is a to-do, not a meeting.
    private static let arrangingVerbs = [
        "schedule", "book", "arrange", "set up", "setup", "organise", "organize",
        "plan ", "find a time", "reschedule", "confirm", "ask about", "email about",
        "call to", "reach out", "follow up"
    ]

    /// Should this become a real calendar event? Only when the model says it's an appointment,
    /// it has a genuine time (not a whole-day placeholder), and the title isn't about
    /// *arranging* something. Writing to someone's real calendar deserves all three.
    static func isRealAppointment(title: String, isAppointment: Bool, dueDate: String?, isAllDay: Bool) -> Bool {
        guard isAppointment, !isAllDay, dueDate != nil else { return false }
        let lower = title.lowercased()
        return !arrangingVerbs.contains { lower.hasPrefix($0) || lower.contains(" \($0)") }
    }

    /// Guardrail against under-prioritized imminent work: something due today or already
    /// overdue is never "low", even when the user's phrasing was casual (a common source of
    /// the model mis-calling priority). Only lifts low→medium; the model's high/medium calls
    /// and anything without a near-term due date are left untouched.
    static func resolvedPriority(_ priority: String, dueDate: String?, now: Date, calendar: Calendar = .current) -> String {
        guard priority == "low", let due = DueDate.parse(dueDate) else { return priority }
        let todayOrOverdue = calendar.isDate(due, inSameDayAs: now) || due < now
        return todayOrOverdue ? "medium" : "low"
    }

    /// Encode context tags as a JSON array string: lowercased, restricted to the allowed
    /// vocabulary, de-duplicated, order-preserving. Returns nil when nothing valid remains.
    static func encodeTags(_ tags: [String]) -> String? {
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { allowedContextTags.contains($0) && seen.insert($0).inserted }
        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
