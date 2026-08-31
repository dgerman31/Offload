import Testing
import Foundation
@testable import Offload

/// Choosing *which* past corrections to show the model.
///
/// A prompt has a finite budget for worked examples, and six lessons about grocery categories teach
/// nothing about a capture on renal physiology. Ranking by resemblance rather than recency is the
/// cheapest quality gain available, and unlike an embedding lookup it costs no network call in the
/// capture hot path.
struct PersonalizationRelevanceTests {

    private func correction(_ field: String, taskId: String, from: String, to: String, at day: Int) -> Correction {
        var c = Correction(taskId: taskId, field: field, modelValue: from, userValue: to)
        c.createdAt = String(format: "2026-07-%02dT12:00:00Z", day)
        return c
    }

    private func task(_ id: String, _ title: String) -> TaskItem {
        TaskItem(id: id, title: title)
    }

    // MARK: Ranking

    @Test("The examples shown are the ones that resemble what was just said")
    func relevanceBeatsRecency() {
        let tasks = [task("t1", "Buy oat milk and bread"), task("t2", "Renal physiology Anki deck")]
        let corrections = [
            correction("category", taskId: "t1", from: "Work", to: "Personal", at: 20),   // newest
            correction("category", taskId: "t2", from: "Personal", to: "Work", at: 10)
        ]
        let lessons = Personalization.lessons(corrections: corrections, tasks: tasks, limit: 1,
                                              matching: "need to get through the renal deck tonight")
        #expect(lessons.first?.taskTitle == "Renal physiology Anki deck")
    }

    @Test("With nothing to match against, the newest still wins")
    func recencyIsTheFallback() {
        let tasks = [task("t1", "Buy oat milk"), task("t2", "Renal physiology deck")]
        let corrections = [
            correction("category", taskId: "t1", from: "Work", to: "Personal", at: 20),
            correction("category", taskId: "t2", from: "Personal", to: "Work", at: 10)
        ]
        let lessons = Personalization.lessons(corrections: corrections, tasks: tasks, limit: 1)
        #expect(lessons.first?.taskTitle == "Buy oat milk")
    }

    @Test("A transcript that resembles nothing still returns the newest, not nothing")
    func noOverlapDegradesToRecency() {
        let tasks = [task("t1", "Buy oat milk"), task("t2", "Renal physiology deck")]
        let corrections = [
            correction("category", taskId: "t1", from: "Work", to: "Personal", at: 20),
            correction("category", taskId: "t2", from: "Personal", to: "Work", at: 10)
        ]
        let lessons = Personalization.lessons(corrections: corrections, tasks: tasks, limit: 2,
                                              matching: "completely unrelated sentence about weather")
        #expect(lessons.count == 2)
        #expect(lessons.first?.taskTitle == "Buy oat milk")   // recency order preserved on a tie
    }

    // MARK: Scoring

    @Test("Relevance measures how much of the title the capture echoes")
    func relevanceScoring() {
        #expect(Personalization.relevance(of: "Renal physiology deck",
                                          to: "the renal physiology deck tonight") == 1.0)
        #expect(Personalization.relevance(of: "Renal physiology deck", to: "buy milk") == 0)
    }

    @Test("Common words don't create false matches")
    func stopwordsAreIgnored() {
        // Without a stopword list, "I need to have the thing" would look related to everything.
        #expect(Personalization.relevance(of: "Buy oat milk", to: "I need to have that and this") == 0)
        #expect(Personalization.tokens("I need to have the thing").isEmpty == false)
        #expect(Personalization.tokens("I need to have the").isEmpty)
    }

    // MARK: Kind lessons

    @Test("A reclassification is taught as what the thing is, not as a column value")
    func kindLessonsReadAsFacts() throws {
        let tasks = [task("t1", "Could run it off the topic list")]
        let corrections = [correction("kind", taskId: "t1", from: "task", to: "idea", at: 20)]
        let lessons = Personalization.lessons(corrections: corrections, tasks: tasks)
        let fragment = try #require(Personalization.promptFragment(lessons))
        #expect(fragment.contains("is an idea, not a to-do"))
        #expect(fragment.contains("Could run it off the topic list"))
    }

    @Test("Kind is a field the app learns from")
    func kindIsLearnable() {
        #expect(Personalization.learnableFields.contains("kind"))
    }
}
