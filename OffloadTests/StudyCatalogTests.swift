import Testing
import Foundation
@testable import Offload

/// The Study tab's catalog and duration math — pure data and pure functions, same as
/// `AutoFitTests`/`GymTests`. Card counts here are the user's own real AnKing v12 collection,
/// so these numbers are a fixed contract, not made up.
struct StudyCatalogTests {

    @Test("Anki duration is the subtopic's real card count at 15 sec/card")
    func ankiDurationFromRealCardCount() {
        let neuroStructures = StudySystem.neuro.subtopics.first { $0.name == "Nervous System Structures" }!
        #expect(neuroStructures.ankiCardCount == 849)
        let (minutes, note) = StudyResource.anki.plan(for: neuroStructures)
        #expect(minutes == (849 * 15) / 60)
        #expect(note == "849 cards")
    }

    @Test("UWorld and AMBOSS use fixed default question counts at the user's own pace")
    func questionBasedResourcesUseDefaults() {
        let subtopic = StudySubtopic(name: "Anything", ankiCardCount: 100)
        let (uworldMinutes, uworldNote) = StudyResource.uworld.plan(for: subtopic)
        #expect(uworldNote == "40 questions")
        #expect(uworldMinutes == (40 * 150) / 60)

        let (ambossMinutes, ambossNote) = StudyResource.amboss.plan(for: subtopic)
        #expect(ambossNote == "20 questions")
        #expect(ambossMinutes == (20 * 150) / 60)
    }

    @Test("First Aid and Sketchy get a fixed duration, independent of card count")
    func fixedDurationResourcesIgnoreCardCount() {
        let small = StudySubtopic(name: "Small", ankiCardCount: 10)
        let large = StudySubtopic(name: "Large", ankiCardCount: 5000)
        #expect(StudyResource.firstAid.plan(for: small).minutes == StudyResource.firstAid.plan(for: large).minutes)
        #expect(StudyResource.sketchy.plan(for: small).minutes == StudyResource.sketchy.plan(for: large).minutes)
    }

    @Test("Total Anki cards per system match the real, deduplicated collection counts")
    func systemTotalsMatchRealCounts() {
        #expect(StudySystem.neuro.totalAnkiCards == 2389)
        #expect(StudySystem.hematology.totalAnkiCards == 1750)
        #expect(StudySystem.repro.totalAnkiCards == 1487)
    }

    @Test("makeTask builds a Study-category task with the deterministic title and computed effort")
    func makeTaskBuildsExpectedFields() {
        let subtopic = StudySystem.hematology.subtopics.first { $0.name == "Hemostasis" }!
        let task = StudyCatalog.makeTask(system: .hematology, subtopic: subtopic, resource: .anki)
        #expect(task.title == "Anki: Hematology – Hemostasis")
        #expect(task.category == "Study")
        #expect(task.descriptionText == "464 cards")
        #expect(task.effortMinutes == (464 * 15) / 60)
        #expect(task.dueDate == nil)   // left unscheduled for AutoFit to place
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

    @Test("Every subtopic's title is unique per system, so 'already added today' matching by title is unambiguous")
    func titlesAreUniquePerSystem() {
        for system in StudySystem.allCases {
            let titles = system.subtopics.map(\.name)
            #expect(Set(titles).count == titles.count)
        }
    }
}
