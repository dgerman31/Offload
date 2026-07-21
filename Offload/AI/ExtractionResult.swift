import Foundation

/// What an extractor hands back. Extraction produces the structured `capture`, and — when the
/// model is capable enough to reason about its own uncertainty (Gemini) — a few `chips`: fast,
/// tappable refinements for the genuinely ambiguous parts of a capture. The on-device fallback
/// returns no chips and no command judgment, so those fields are simply empty/`nil` there.
///
/// `isProjectCommand` is Gemini's own read on "is the user telling the app to CREATE a project
/// (a command) or describing work they need to do (a task)?" — the judgment that used to be a
/// brittle regex in `CaptureMapper`. `nil` means "the model didn't judge" (on-device path), so
/// the mapper falls back to its lightweight regex.
struct ExtractionResult: Sendable {
    var capture: ExtractedCapture
    var chips: [ClarifyChip] = []
    var isProjectCommand: Bool? = nil
}

/// A single deterministic refinement offered after capture. Gemini surfaces these ONLY when it
/// is genuinely unsure (an ambiguous due date, a maybe-project, a possible weekly repeat) —
/// never on a slam-dunk capture. Tapping one applies a small, local patch to the just-saved
/// task(s); there is no network round-trip to APPLY a choice, only to suggest it.
struct ClarifyChip: Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    /// The pill's text, e.g. "Tomorrow", "Bump to high", "Repeat weekly".
    var label: String
    var action: ChipAction

    /// Chips in the same group answer the same question (the four due-date chips, say). Tapping
    /// one resolves the question, so the UI clears the whole group at once.
    var group: String { action.group }
}

/// The deterministic effect a chip has when tapped. Kept small and closed: an unknown action
/// coming back from the model is dropped rather than trusted, since a chip writes to a task.
enum ChipAction: Sendable, Equatable {
    case dueToday
    case dueTomorrow
    case dueThisWeek
    case clearDue
    case bumpPriorityHigh
    case recurWeekly
    case setCategory(String)
    case assignProject(String)

    var group: String {
        switch self {
        case .dueToday, .dueTomorrow, .dueThisWeek, .clearDue: return "due"
        case .bumpPriorityHigh:                                return "priority"
        case .recurWeekly:                                     return "recurrence"
        case .setCategory:                                     return "category"
        case .assignProject:                                   return "project"
        }
    }

    /// Parse the model's wire form (an action key + optional value) into a typed action, or nil
    /// if the key is unknown — the sanity backstop that keeps a garbled suggestion from becoming
    /// a task edit.
    static func parse(key: String, value: String?) -> ChipAction? {
        switch key {
        case "due_today":     return .dueToday
        case "due_tomorrow":  return .dueTomorrow
        case "due_this_week": return .dueThisWeek
        case "due_clear":     return .clearDue
        case "priority_high": return .bumpPriorityHigh
        case "recur_weekly":  return .recurWeekly
        case "set_category":
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return .setCategory(v)
        case "assign_project":
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return .assignProject(v)
        default:
            return nil
        }
    }
}

extension ClarifyChip {
    /// The per-task portion of a chip's effect: a pure, deterministic patch. Project assignment
    /// isn't here — it creates/links a container and is handled by `CaptureService` — so this
    /// returns the task unchanged for `.assignProject`.
    func patch(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) -> TaskItem {
        var t = task
        switch action {
        case .dueToday:
            setDay(&t, calendar.startOfDay(for: now), calendar: calendar)
        case .dueTomorrow:
            setDay(&t, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now, calendar: calendar)
        case .dueThisWeek:
            // "This week" = a soft nudge a few days out, kept whole-day so it reads as an
            // intention, not a fake clock time.
            setDay(&t, calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now)) ?? now, calendar: calendar)
        case .clearDue:
            t.dueDate = nil
            t.dueIsAllDay = false
            t.dueDateConfidence = nil
        case .bumpPriorityHigh:
            t.priority = "high"
        case .recurWeekly:
            if (t.recurrenceRule ?? "").isEmpty { t.recurrenceRule = "FREQ=WEEKLY" }
        case .setCategory(let name):
            t.category = CaptureMapper.normalizedCategory(name)
        case .assignProject:
            break   // handled by the service (needs to create/link a Project)
        }
        return t
    }

    private func setDay(_ t: inout TaskItem, _ date: Date, calendar: Calendar) {
        t.dueDate = DueDate.canonicalString(from: calendar.startOfDay(for: date))
        t.dueIsAllDay = true
        t.dueDateConfidence = 0.7   // the user tapped it — a fairly confident soft date
    }
}
