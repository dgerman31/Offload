import Testing
import Foundation
@testable import Offload

/// The Study tab's catalog and duration math — pure data and pure functions, same as
/// `AutoFitTests`/`GymTests`. Card counts here are the user's own real AnKing v12 collection,
/// so these numbers are a fixed contract, not made up.
struct StudyCatalogTests {

    @Test("Anki duration prices a node's cards as new cards, learning steps and all")
    func ankiDurationFromRealCardCount() {
        // This used to assert `cards × 15s`, which is the time it would take if every card were
        // right first try. Every card under a catalog node is unseen, so the honest model is the
        // new-card one: two consecutive correct answers with the streak reset by an "Again". The
        // old figure wasn't slightly low — it was out by a factor of about 3.5.
        let neuroStructures = StudySystem.neuro.subtopics.first { $0.name == "Nervous System Structures" }!
        #expect(neuroStructures.ankiCardCount == 849)
        #expect(StudyCatalog.ankiMinutes(forCards: 849) == AnkiLoad.minutesForNewCards(849))
        #expect(StudyCatalog.ankiMinutes(forCards: 849) > 3 * (849 * 15) / 60)

        let leaf = neuroStructures.leaves.first { $0.name == "Cranial Nerves" }!
        #expect(leaf.ankiCardCount == 135)
        #expect(StudyCatalog.ankiMinutes(forCards: 135) == AnkiLoad.minutesForNewCards(135))

        // Still proportional to the card count — the change is the multiplier, not the shape.
        // Compared within a minute rather than exactly, because minutes round *up*: doubling 118
        // gives 236 while 270 cards come to 235, and the missing minute is the rounding, not a
        // non-linearity.
        let doubled = StudyCatalog.ankiMinutes(forCards: 270)
        #expect(abs(doubled - 2 * StudyCatalog.ankiMinutes(forCards: 135)) <= 1)
        #expect(StudyCatalog.ankiMinutes(forCards: 1) >= 1)
    }

    @Test("First Aid, UWorld, AMBOSS, and Sketchy use fixed defaults, independent of any subtopic")
    func systemLevelResourcesUseFixedDefaults() {
        let (uworldMinutes, uworldNote) = StudyResource.uworld.plan
        #expect(uworldNote == "40 questions")
        #expect(uworldMinutes == (40 * 150) / 60)

        let (ambossMinutes, ambossNote) = StudyResource.amboss.plan
        #expect(ambossNote == "20 questions")
        #expect(ambossMinutes == (20 * 150) / 60)

        #expect(StudyResource.firstAid.plan.minutes == StudyResource.defaultFirstAidMinutes)
        #expect(StudyResource.sketchy.plan.minutes == StudyResource.defaultSketchyMinutes)
    }

    @Test("Total Anki cards per system match the real, deduplicated collection counts")
    func systemTotalsMatchRealCounts() {
        #expect(StudySystem.neuro.totalAnkiCards == 2389)
        #expect(StudySystem.hematology.totalAnkiCards == 1750)
        #expect(StudySystem.repro.totalAnkiCards == 1487)
    }

    @Test("Every system has at least one subtopic, and every subtopic has at least one leaf")
    func everySubtopicHasLeaves() {
        for system in StudySystem.allCases {
            #expect(!system.subtopics.isEmpty)
            for subtopic in system.subtopics {
                #expect(!subtopic.leaves.isEmpty, "\(system.rawValue) – \(subtopic.name) has no leaves")
            }
        }
    }

    @Test("makeAnkiTask builds a Study-category task with the deterministic title and computed effort")
    func makeAnkiTaskBuildsExpectedFields() {
        let subtopic = StudySystem.hematology.subtopics.first { $0.name == "Hemostasis" }!
        let task = StudyCatalog.makeAnkiTask(system: .hematology, nodeName: subtopic.name, cardCount: subtopic.ankiCardCount)
        #expect(task.title == "Anki: Hematology – Hemostasis")
        #expect(task.category == "Study")
        #expect(task.descriptionText == "464 cards")
        #expect(task.effortMinutes == AnkiLoad.minutesForNewCards(464))
        #expect(task.dueDate == nil)   // left unscheduled for AutoFit/end-of-day placement

        let leaf = subtopic.leaves.first { $0.name == "Anticoagulant Drugs" }!
        let leafTask = StudyCatalog.makeAnkiTask(system: .hematology, nodeName: leaf.name, cardCount: leaf.ankiCardCount)
        #expect(leafTask.title == "Anki: Hematology – Anticoagulant Drugs")
        #expect(leafTask.descriptionText == "95 cards")
    }

    @Test("makeResourceTask is a plain standalone block, not tied to any system or subtopic")
    func makeResourceTaskIsStandalone() {
        let task = StudyCatalog.makeResourceTask(.firstAid)
        #expect(task.title == "First Aid")
        #expect(task.category == "Study")
        #expect(task.effortMinutes == StudyResource.defaultFirstAidMinutes)
    }

    @Test("The nightly AMBOSS mixed review task defaults to 10 questions, ~25 minutes")
    func ambossMixedReviewDefaults() {
        let task = StudyCatalog.makeAmbossMixedReviewTask()
        #expect(task.title == "AMBOSS Mixed Review")
        #expect(task.descriptionText == "10 questions")
        #expect(task.effortMinutes == 25)
        #expect(task.category == "Study")
    }

    @Test("A custom AMBOSS mixed review question count scales duration linearly")
    func ambossMixedReviewCustomCount() {
        let task = StudyCatalog.makeAmbossMixedReviewTask(questionCount: 20)
        #expect(task.descriptionText == "20 questions")
        #expect(task.effortMinutes == 50)
    }

    @Test("Subtopic names are unique per system, and leaf names are unique within their subtopic")
    func namesAreUniqueEnoughForTitleMatching() {
        for system in StudySystem.allCases {
            let subtopicNames = system.subtopics.map(\.name)
            #expect(Set(subtopicNames).count == subtopicNames.count)
            for subtopic in system.subtopics {
                let leafNames = subtopic.leaves.map(\.name)
                #expect(Set(leafNames).count == leafNames.count)
            }
        }
    }
}
