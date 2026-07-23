import Foundation

/// The Study tab's catalog: real reference data plus the pure math behind every scheduled
/// study block. There's no parallel "session" model here the way Gym has `WorkoutSession` —
/// picking a subtopic/resource just builds an ordinary `TaskItem` (see `StudyView`'s doc
/// comment for why), so everything below is plain, unit-testable data and functions.
///
/// Card counts are the user's own real AnKing v12 collection — Step1, tagged under B&B (their
/// actual study resource) — read directly off their Anki database this session and deduplicated
/// (a card carrying two subtags under the same subject was briefly double-counted before that
/// was caught), not estimated or looked up online.
enum StudySystem: String, CaseIterable, Identifiable {
    case neuro = "Neuro"
    case hematology = "Hematology"
    case repro = "Repro"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .neuro:      return "brain.head.profile"
        case .hematology: return "drop.fill"
        case .repro:      return "figure.2"
        }
    }

    var subtopics: [StudySubtopic] {
        switch self {
        case .neuro:
            return [
                StudySubtopic(name: "Introduction to Neurology", ankiCardCount: 280),
                StudySubtopic(name: "Nervous System Structures", ankiCardCount: 849),
                StudySubtopic(name: "Neurovascular Disorders", ankiCardCount: 240),
                StudySubtopic(name: "Autonomic Nervous System", ankiCardCount: 427),
                StudySubtopic(name: "Other Neurology Topics", ankiCardCount: 775),
            ]
        case .hematology:
            return [
                StudySubtopic(name: "Hemostasis", ankiCardCount: 464),
                StudySubtopic(name: "Red Blood Cells", ankiCardCount: 613),
                StudySubtopic(name: "White Blood Cells", ankiCardCount: 421),
                StudySubtopic(name: "Cancer Drugs", ankiCardCount: 243),
                StudySubtopic(name: "Other", ankiCardCount: 45),
            ]
        case .repro:
            return [
                StudySubtopic(name: "Embryology", ankiCardCount: 303),
                StudySubtopic(name: "Pregnancy", ankiCardCount: 449),
                StudySubtopic(name: "Vagina, Cervix & Uterus", ankiCardCount: 201),
                StudySubtopic(name: "Ovary", ankiCardCount: 118),
                StudySubtopic(name: "Breast", ankiCardCount: 169),
                StudySubtopic(name: "Male Disorders", ankiCardCount: 259),
                StudySubtopic(name: "Other", ankiCardCount: 112),
            ]
        }
    }

    /// Total real, *distinct* Anki cards for the whole system — shown as the system's own
    /// summary. Deliberately not a sum of the subtopic counts above: a card can carry more than
    /// one subtopic subtag at once (the exact double-counting bug this session already found
    /// and fixed once, at the system-tag level), so summing would overstate the true total by
    /// however many cards straddle two subtopics. These are the verified deduplicated counts
    /// read directly off the real collection.
    var totalAnkiCards: Int {
        switch self {
        case .neuro:      return 2389
        case .hematology: return 1750
        case .repro:      return 1487
        }
    }
}

struct StudySubtopic: Identifiable, Hashable {
    var name: String
    var ankiCardCount: Int
    var id: String { name }
}

/// The five ways to study a subtopic. Anki's duration comes straight from the subtopic's real
/// card count at the user's own stated pace; the other four have no clean natural unit in the
/// data, so they're a fixed default (a question count for UWorld/AMBOSS, a plain duration for
/// First Aid/Sketchy) — never fabricated precision, and always editable afterward through the
/// task's own normal edit screen like any other task.
enum StudyResource: String, CaseIterable, Identifiable {
    case anki = "Anki"
    case firstAid = "First Aid"
    case uworld = "UWorld"
    case amboss = "AMBOSS"
    case sketchy = "Sketchy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .anki:     return "rectangle.stack.fill"
        case .firstAid: return "book.fill"
        case .uworld:   return "checklist"
        case .amboss:   return "list.bullet.clipboard.fill"
        case .sketchy:  return "pencil.and.outline"
        }
    }

    /// Seconds per unit, at the user's own stated pace (15 sec/Anki card; ~2.5 min/question for
    /// both UWorld and AMBOSS alike).
    private static let secondsPerAnkiCard = 15
    private static let secondsPerQuestion = 150

    static let defaultUWorldQuestions = 40
    static let defaultAmbossSubtopicQuestions = 20
    static let defaultFirstAidMinutes = 30
    static let defaultSketchyMinutes = 20

    /// Minutes and a short human-readable volume note for this resource against a subtopic.
    func plan(for subtopic: StudySubtopic) -> (minutes: Int, note: String) {
        switch self {
        case .anki:
            let seconds = subtopic.ankiCardCount * Self.secondsPerAnkiCard
            return (max(1, seconds / 60), "\(subtopic.ankiCardCount) cards")
        case .uworld:
            let q = Self.defaultUWorldQuestions
            return ((q * Self.secondsPerQuestion) / 60, "\(q) questions")
        case .amboss:
            let q = Self.defaultAmbossSubtopicQuestions
            return ((q * Self.secondsPerQuestion) / 60, "\(q) questions")
        case .firstAid:
            return (Self.defaultFirstAidMinutes, "reading")
        case .sketchy:
            return (Self.defaultSketchyMinutes, "video")
        }
    }
}

enum StudyCatalog {
    static let category = "Study"

    /// The exact, deterministic title Study always builds for a subtopic/resource pick — also
    /// how the tab tells which combos already have a task on today's schedule (matching by
    /// title rather than a hidden field: `contextTags` is a real, user-visible AI feature
    /// already rendered as chips on the row, so it isn't free real estate for bookkeeping).
    static func title(system: StudySystem, subtopic: StudySubtopic, resource: StudyResource) -> String {
        "\(resource.rawValue): \(system.rawValue) – \(subtopic.name)"
    }

    static let ambossMixedReviewTitle = "AMBOSS Mixed Review"

    /// Build (but don't yet fit-into-today or persist) the task for one subtopic/resource pick.
    static func makeTask(system: StudySystem, subtopic: StudySubtopic, resource: StudyResource) -> TaskItem {
        let (minutes, note) = resource.plan(for: subtopic)
        return TaskItem(
            title: title(system: system, subtopic: subtopic, resource: resource),
            descriptionText: note,
            category: category,
            effortMinutes: minutes
        )
    }

    /// The standing nightly quick-add — not tied to any system/subtopic, always available.
    static func makeAmbossMixedReviewTask(questionCount: Int = 10) -> TaskItem {
        let minutes = (questionCount * 150) / 60
        return TaskItem(
            title: ambossMixedReviewTitle,
            descriptionText: "\(questionCount) questions",
            category: category,
            effortMinutes: max(1, minutes)
        )
    }
}
