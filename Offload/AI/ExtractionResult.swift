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
    /// Which extractor actually produced this, as stored in `captures.model_source` — the app's
    /// only record of cloud-vs-on-device work. `nil` means the producer didn't say; `CaptureService`
    /// resolves that rather than guessing (it used to hardcode `"foundation"` for every capture,
    /// including the ones Gemini did, which made the whole column a constant).
    var modelSource: String? = nil
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
    /// Reclassify: "that's an idea, not a to-do". The most consequential chip there is — it decides
    /// whether the thing can be scheduled at all — so it's also the one the model is told to offer
    /// whenever it's genuinely torn.
    case setKind(CaptureKind)

    var group: String {
        switch self {
        case .dueToday, .dueTomorrow, .dueThisWeek, .clearDue: return "due"
        case .bumpPriorityHigh:                                return "priority"
        case .recurWeekly:                                     return "recurrence"
        case .setCategory:                                     return "category"
        case .assignProject:                                   return "project"
        case .setKind:                                         return "kind"
        }
    }

    /// Parse the model's wire form (an action key + optional value) into a typed action, or nil
    /// if the key is unknown — the sanity backstop that keeps a garbled suggestion from becoming
    /// a task edit.
    static func parse(key: String, value: String?) -> ChipAction? {
        switch key {
        case "due_today":              return .dueToday
        case "due_tomorrow":           return .dueTomorrow
        case "due_this_week":          return .dueThisWeek
        case "due_none", "due_clear":  return .clearDue      // accept both spellings
        case "priority_high":          return .bumpPriorityHigh
        case "repeat_weekly", "recur_weekly": return .recurWeekly
        case "set_category":
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return .setCategory(v)
        case "assign_project":
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return .assignProject(v)
        case "set_kind":
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return .setKind(CaptureKind.parse(v))
        default:
            return nil
        }
    }
}

extension ClarifyChip {

    /// Below this, the app asks instead of asserting.
    static let confidenceThreshold = 0.7

    /// Make sure an unsure capture actually asks the question it's unsure about.
    ///
    /// The model is told to offer a `set_kind` pair whenever it's torn, and it usually will — but
    /// "usually" is not a guarantee, and the failure is silent and expensive: a low-confidence
    /// guess presented as a fact is exactly how an idea ends up as a chore. So when confidence is
    /// low and the model didn't ask, the app asks for it.
    ///
    /// Both options are offered, including the one already chosen. Tapping the current kind is a
    /// no-op on the task and a confirmation to the ledger, which is worth as much as a correction —
    /// the model finds out when it was right to be unsure and right anyway.
    static func withKindFallback(
        _ chips: [ClarifyChip],
        capture: ExtractedCapture,
        threshold: Double = confidenceThreshold
    ) -> [ClarifyChip] {
        guard let confidence = capture.confidence, confidence < threshold else { return chips }
        guard !chips.contains(where: { $0.group == "kind" }) else { return chips }
        guard let first = capture.tasks.first else { return chips }
        let current = CaptureKind.parse(first.kind)
        // The question is nearly always "is this something to do, or something I thought?" — so
        // the alternative offered is the other side of that, whichever side we're on.
        let alternative: CaptureKind = current == .idea ? .task : .idea
        guard alternative != current else { return chips }
        return chips + [
            ClarifyChip(label: current.label, action: .setKind(current)),
            ClarifyChip(label: alternative.label, action: .setKind(alternative))
        ]
    }

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
        case .setKind(let kind):
            t.kind = kind.rawValue
            // Reclassifying out of a schedulable kind has to take the schedule with it. Otherwise
            // "that's an idea, not a to-do" leaves an idea sitting in tomorrow's plan, going
            // overdue — which is precisely the thing the taxonomy exists to stop.
            if !kind.isSchedulable {
                t.dueDate = nil
                t.dueIsAllDay = false
                t.dueDateConfidence = nil
                t.deadline = nil
                t.recurrenceRule = nil
                t.pinned = false
            }
        }
        return t
    }

    private func setDay(_ t: inout TaskItem, _ date: Date, calendar: Calendar) {
        t.dueDate = DueDate.canonicalString(from: calendar.startOfDay(for: date))
        t.dueIsAllDay = true
        t.dueDateConfidence = 0.7   // the user tapped it — a fairly confident soft date
    }
}
