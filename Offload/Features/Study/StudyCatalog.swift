import Foundation

/// The Study tab's catalog: real reference data plus the pure math behind every scheduled
/// study block. There's no parallel "session" model here the way Gym has `WorkoutSession` —
/// picking anything just builds an ordinary `TaskItem` (see `StudyView`'s doc comment) — so
/// everything below is plain, unit-testable data and functions.
///
/// Anki's numbers are the user's own real AnKing v12 collection — Step1, tagged under B&B
/// (their actual study resource), read directly off their Anki database and deduplicated at
/// every level (a card can carry more than one subtag under the same subject or subtopic, which
/// was caught and fixed twice already — once at the system level, once at the subtopic level —
/// so each stored total below is the *verified distinct* count for that exact node, not a sum of
/// its children, which would double-count any card spanning two of them).
///
/// First Aid, UWorld, AMBOSS, and Sketchy are deliberately **not** part of this per-subtopic
/// Anki tree — the user was explicit that they're a separate, system-level thing ("not a per
/// topic thing"), so each is one pickable block per system, not per subtopic.
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

    /// The system's own verified distinct Anki card count — not a sum of `subtopics`, which
    /// would overstate it (see the type's doc comment).
    var totalAnkiCards: Int {
        switch self {
        case .neuro:      return 2389
        case .hematology: return 1750
        case .repro:      return 1487
        }
    }

    var subtopics: [StudySubtopic] {
        switch self {
        case .neuro:
            return [
                StudySubtopic(name: "Introduction to Neurology", ankiCardCount: 280, leaves: [
                    .init(name: "Cells of the Nervous System", ankiCardCount: 64),
                    .init(name: "Nerve Damage", ankiCardCount: 64),
                    .init(name: "Blood Brain Barrier", ankiCardCount: 26),
                    .init(name: "Neurotransmitters", ankiCardCount: 57),
                    .init(name: "Dermatomes and Reflexes", ankiCardCount: 75),
                ]),
                StudySubtopic(name: "Nervous System Structures", ankiCardCount: 849, leaves: [
                    .init(name: "Cerebral Cortex", ankiCardCount: 70),
                    .init(name: "Spinal Cord", ankiCardCount: 82),
                    .init(name: "Spinal Cord Syndromes", ankiCardCount: 89),
                    .init(name: "Brainstem", ankiCardCount: 113),
                    .init(name: "Cranial Nerves", ankiCardCount: 135),
                    .init(name: "Auditory System", ankiCardCount: 30),
                    .init(name: "Vestibular System", ankiCardCount: 28),
                    .init(name: "Thalamus, Hypothalamus & Limbic System", ankiCardCount: 122),
                    .init(name: "Cerebellum", ankiCardCount: 98),
                    .init(name: "Basal Ganglia", ankiCardCount: 46),
                    .init(name: "Ventricles and Sinuses", ankiCardCount: 86),
                ]),
                StudySubtopic(name: "Neurovascular Disorders", ankiCardCount: 240, leaves: [
                    .init(name: "Cerebral and Lacunar Strokes", ankiCardCount: 67),
                    .init(name: "Vertebrobasilar Stroke Syndromes", ankiCardCount: 43),
                    .init(name: "CNS Aneurysms", ankiCardCount: 31),
                    .init(name: "Intracranial Bleeding", ankiCardCount: 89),
                    .init(name: "Management of TIA/Stroke", ankiCardCount: 32),
                ]),
                StudySubtopic(name: "Autonomic Nervous System", ankiCardCount: 427, leaves: [
                    .init(name: "Autonomic Nervous System", ankiCardCount: 183),
                    .init(name: "ANS Drugs: Norepinephrine", ankiCardCount: 136),
                    .init(name: "ANS Drugs: Acetylcholine", ankiCardCount: 81),
                    .init(name: "Autonomic Receptors", ankiCardCount: 87),
                ]),
                StudySubtopic(name: "Other Neurology Topics", ankiCardCount: 775, leaves: [
                    .init(name: "Meningitis", ankiCardCount: 103),
                    .init(name: "Seizures", ankiCardCount: 105),
                    .init(name: "Neuroembryology", ankiCardCount: 90),
                    .init(name: "Delirium and Dementia", ankiCardCount: 99),
                    .init(name: "Demyelinating Diseases", ankiCardCount: 71),
                    .init(name: "Headaches", ankiCardCount: 64),
                    .init(name: "Brain Tumors", ankiCardCount: 90),
                    .init(name: "Parkinson's, Huntington's & Movement Disorders", ankiCardCount: 98),
                    .init(name: "HIV CNS Infections", ankiCardCount: 34),
                    .init(name: "Neuromuscular Disorders", ankiCardCount: 37),
                ]),
            ]
        case .hematology:
            return [
                StudySubtopic(name: "Hemostasis", ankiCardCount: 464, leaves: [
                    .init(name: "Coagulation", ankiCardCount: 100),
                    .init(name: "Platelet Activation", ankiCardCount: 57),
                    .init(name: "Hypercoagulable States", ankiCardCount: 83),
                    .init(name: "Coagulopathies", ankiCardCount: 46),
                    .init(name: "Platelet Disorders", ankiCardCount: 138),
                    .init(name: "Antiplatelet Drugs", ankiCardCount: 49),
                    .init(name: "Anticoagulant Drugs", ankiCardCount: 95),
                ]),
                StudySubtopic(name: "Red Blood Cells", ankiCardCount: 613, leaves: [
                    .init(name: "Hemolysis Basics", ankiCardCount: 60),
                    .init(name: "Extrinsic Hemolysis", ankiCardCount: 76),
                    .init(name: "Intrinsic Hemolysis", ankiCardCount: 117),
                    .init(name: "Microcytic Anemias", ankiCardCount: 159),
                    .init(name: "Thalassemias", ankiCardCount: 79),
                    .init(name: "Sickle Cell Anemia", ankiCardCount: 110),
                    .init(name: "Other Anemias", ankiCardCount: 62),
                    .init(name: "Blood Groups", ankiCardCount: 53),
                ]),
                StudySubtopic(name: "White Blood Cells", ankiCardCount: 421, leaves: [
                    .init(name: "Acute Leukemia", ankiCardCount: 78),
                    .init(name: "Chronic Leukemia", ankiCardCount: 63),
                    .init(name: "Hodgkin Lymphoma", ankiCardCount: 47),
                    .init(name: "Non-Hodgkin Lymphoma", ankiCardCount: 92),
                    .init(name: "Plasma Cell Disorders", ankiCardCount: 55),
                    .init(name: "Amyloidosis", ankiCardCount: 43),
                    .init(name: "Myeloproliferative Disorders", ankiCardCount: 79),
                ]),
                StudySubtopic(name: "Cancer Drugs", ankiCardCount: 243, leaves: [
                    .init(name: "Antimetabolites", ankiCardCount: 73),
                    .init(name: "Alkylating Agents", ankiCardCount: 39),
                    .init(name: "Antitumor Antibiotics", ankiCardCount: 35),
                    .init(name: "Microtubule Inhibitors", ankiCardCount: 22),
                    .init(name: "DNA Drugs", ankiCardCount: 24),
                    .init(name: "Other Cancer Drugs", ankiCardCount: 54),
                ]),
                StudySubtopic(name: "Other", ankiCardCount: 45, leaves: [
                    .init(name: "Porphyrias", ankiCardCount: 45),
                ]),
            ]
        case .repro:
            return [
                StudySubtopic(name: "Embryology", ankiCardCount: 303, leaves: [
                    .init(name: "Embryonic Genes", ankiCardCount: 13),
                    .init(name: "Embryogenesis", ankiCardCount: 12),
                    .init(name: "Germ Layers", ankiCardCount: 30),
                    .init(name: "Errors in Morphogenesis", ankiCardCount: 15),
                    .init(name: "Teratogens I", ankiCardCount: 54),
                    .init(name: "Teratogens II", ankiCardCount: 36),
                    .init(name: "Pharyngeal Arches", ankiCardCount: 55),
                    .init(name: "Cleft Lip and Palate", ankiCardCount: 4),
                    .init(name: "Pharyngeal Pouches and Clefts", ankiCardCount: 25),
                    .init(name: "Genital Embryology", ankiCardCount: 71),
                ]),
                StudySubtopic(name: "Pregnancy", ankiCardCount: 449, leaves: [
                    .init(name: "Spermatogenesis and Oogenesis", ankiCardCount: 48),
                    .init(name: "Placenta", ankiCardCount: 34),
                    .init(name: "Twins", ankiCardCount: 14),
                    .init(name: "Pregnancy", ankiCardCount: 55),
                    .init(name: "Maternal-Fetal Disorders", ankiCardCount: 81),
                    .init(name: "Hypertension in Pregnancy", ankiCardCount: 36),
                    .init(name: "Placental Complications", ankiCardCount: 49),
                    .init(name: "Gestational Tumors", ankiCardCount: 62),
                    .init(name: "TORCH Infections", ankiCardCount: 81),
                ]),
                StudySubtopic(name: "Vagina, Cervix & Uterus", ankiCardCount: 201, leaves: [
                    .init(name: "Vaginal Cancer", ankiCardCount: 29),
                    .init(name: "Cervical Cancer", ankiCardCount: 56),
                    .init(name: "Endometrial Disorders", ankiCardCount: 43),
                    .init(name: "Endometriosis", ankiCardCount: 31),
                    .init(name: "Endometrial Cancer", ankiCardCount: 51),
                ]),
                StudySubtopic(name: "Ovary", ankiCardCount: 118, leaves: [
                    .init(name: "Ovarian Cysts", ankiCardCount: 17),
                    .init(name: "Ovarian Epithelial Tumors", ankiCardCount: 39),
                    .init(name: "Ovarian Stromal Tumors", ankiCardCount: 20),
                    .init(name: "Ovarian Germ Cell Tumors", ankiCardCount: 44),
                ]),
                StudySubtopic(name: "Breast", ankiCardCount: 169, leaves: [
                    .init(name: "Breast Tissue", ankiCardCount: 50),
                    .init(name: "Breast Disorders", ankiCardCount: 56),
                    .init(name: "Breast Carcinoma", ankiCardCount: 66),
                ]),
                StudySubtopic(name: "Male Disorders", ankiCardCount: 259, leaves: [
                    .init(name: "Penile Disorders", ankiCardCount: 72),
                    .init(name: "Scrotal Disorders", ankiCardCount: 52),
                    .init(name: "Testicular Cancer", ankiCardCount: 73),
                    .init(name: "Prostate", ankiCardCount: 66),
                ]),
                StudySubtopic(name: "Other", ankiCardCount: 112, leaves: [
                    .init(name: "Disorders of Sexual Development", ankiCardCount: 66),
                    .init(name: "Hypogonadism", ankiCardCount: 54),
                ]),
            ]
        }
    }
}

struct StudySubtopic: Identifiable, Hashable {
    var name: String
    var ankiCardCount: Int
    var leaves: [StudyLeaf] = []
    var id: String { name }
}

struct StudyLeaf: Identifiable, Hashable {
    var name: String
    var ankiCardCount: Int
    var id: String { name }
}

/// A study resource that stands entirely apart from the Anki tree — one per system, not tied to
/// any subtopic or leaf. Each has no clean natural unit in the data, so duration is either a
/// fixed default question count (at the user's own ~2.5 min/question pace) or a fixed plain
/// duration — never fabricated precision — and always editable afterward through the task's own
/// normal edit screen like any other task.
enum StudyResource: String, CaseIterable, Identifiable {
    case firstAid = "First Aid"
    case uworld = "UWorld"
    case amboss = "AMBOSS"
    case sketchy = "Sketchy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .firstAid: return "book.fill"
        case .uworld:   return "checklist"
        case .amboss:   return "list.bullet.clipboard.fill"
        case .sketchy:  return "pencil.and.outline"
        }
    }

    private static let secondsPerQuestion = 150   // ~2.5 min, at the user's own stated pace

    static let defaultUWorldQuestions = 40
    static let defaultAmbossQuestions = 20
    static let defaultFirstAidMinutes = 30
    static let defaultSketchyMinutes = 20

    /// Minutes and a short human-readable volume note for this resource, for one system.
    var plan: (minutes: Int, note: String) {
        switch self {
        case .uworld:
            let q = Self.defaultUWorldQuestions
            return ((q * Self.secondsPerQuestion) / 60, "\(q) questions")
        case .amboss:
            let q = Self.defaultAmbossQuestions
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
    private static let secondsPerAnkiCard = 15

    static func ankiMinutes(forCards count: Int) -> Int {
        max(1, (count * secondsPerAnkiCard) / 60)
    }

    /// The exact, deterministic title Study always builds — also how the tab tells which nodes
    /// already have a task on today's schedule (matching by title rather than a hidden field:
    /// `contextTags` is a real, user-visible AI feature already rendered as chips on the row, so
    /// it isn't free real estate for bookkeeping).
    static func ankiTitle(system: StudySystem, nodeName: String) -> String {
        "Anki: \(system.rawValue) – \(nodeName)"
    }

    static func resourceTitle(system: StudySystem, resource: StudyResource) -> String {
        "\(resource.rawValue): \(system.rawValue)"
    }

    static let ambossMixedReviewTitle = "AMBOSS Mixed Review"

    /// Build (but don't yet schedule or persist) the Anki task for a subtopic or a leaf — both
    /// are just "a named node with a real card count" as far as scheduling is concerned.
    static func makeAnkiTask(system: StudySystem, nodeName: String, cardCount: Int) -> TaskItem {
        TaskItem(
            title: ankiTitle(system: system, nodeName: nodeName),
            descriptionText: "\(cardCount) cards",
            category: category,
            effortMinutes: ankiMinutes(forCards: cardCount)
        )
    }

    /// Build the system-level First Aid/UWorld/AMBOSS/Sketchy task — deliberately not tied to
    /// any subtopic, per the user's explicit "not a per topic thing".
    static func makeResourceTask(system: StudySystem, resource: StudyResource) -> TaskItem {
        let (minutes, note) = resource.plan
        return TaskItem(
            title: resourceTitle(system: system, resource: resource),
            descriptionText: note,
            category: category,
            effortMinutes: minutes
        )
    }

    /// The standing nightly quick-add — not tied to any system/subtopic, always available.
    /// Scheduling this one specifically at the end of the day (rather than the usual
    /// earliest-open-slot placement) is `StudyView`'s job, since it needs to see today's already
    /// scheduled items to know where "the end" is — this just builds the unscheduled task.
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
