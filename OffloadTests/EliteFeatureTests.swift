import Testing
import Foundation
@testable import Offload

/// Tests for the elite pass: hierarchical subtasks, dedup warnings, semantic ranking,
/// and subtask interleaving in Home grouping.
struct EliteFeatureTests {

    /// Deterministic fake: maps known strings to fixed vectors.
    struct FakeEmbedder: TextEmbedding {
        let table: [String: [Double]]
        func vector(for text: String) -> [Double]? { table[text] }
    }

    // MARK: Hierarchical extraction

    @Test("Subtasks become child tasks inheriting category/priority/context")
    func subtaskMapping() {
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Go home", category: "Personal", priority: "medium",
                                  contextTags: ["home"], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: nil,
                                  subtasks: ["Grab charger", "Water plants", "  "])],
            suggestedProject: nil
        )
        let result = CaptureMapper.map(extracted)

        #expect(result.tasks.count == 3)   // parent + 2 children (blank subtask dropped)
        let parent = result.tasks[0]
        let children = result.tasks.dropFirst()
        #expect(children.allSatisfy { $0.parentTaskId == parent.id })
        #expect(children.allSatisfy { $0.category == "Personal" })
        #expect(children.allSatisfy { $0.contextTags == parent.contextTags })
        #expect(children.map(\.title) == ["Grab charger", "Water plants"])
    }

    // MARK: Dedup warnings

    @Test("similarWarnings flags near-duplicates and ignores distinct tasks")
    func dedupWarnings() {
        let embedder = FakeEmbedder(table: [
            "Buy milk": [1, 0],
            "Get milk": [0.98, 0.02],
            "Email boss": [0, 1]
        ])
        let warnings = CaptureService.similarWarnings(
            newTitles: ["Get milk", "Email boss"],
            existingTitles: ["Buy milk"],
            embedder: embedder
        )
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Get milk"))
        #expect(warnings[0].contains("Buy milk"))
    }

    @Test("similarWarnings is empty with no existing tasks or no embeddings")
    func dedupEmpty() {
        let none = FakeEmbedder(table: [:])
        #expect(CaptureService.similarWarnings(newTitles: ["a"], existingTitles: [], embedder: none).isEmpty)
        #expect(CaptureService.similarWarnings(newTitles: ["a"], existingTitles: ["b"], embedder: none).isEmpty)
    }

    // MARK: Semantic search

    @Test("semanticRank orders by similarity and applies the threshold")
    func semanticRanking() {
        let ranked = SearchStore.semanticRank(
            queryVector: [1, 0],
            candidates: [
                (id: "exact", vector: [1, 0]),
                (id: "close", vector: [0.9, 0.1]),
                (id: "far", vector: [0, 1])
            ]
        )
        #expect(ranked == ["exact", "close"])   // "far" below threshold
    }

    // MARK: Home grouping with subtasks

    @Test("Children render indented directly beneath their parent")
    func subtaskInterleaving() {
        let now = Date()
        let parent = TaskItem(title: "Go home", category: "Personal")
        let child = TaskItem(title: "Grab charger", category: "Personal", parentTaskId: parent.id)
        let other = TaskItem(title: "Unrelated", category: "Personal")

        let sections = HomeGrouping.sections(from: [parent, other, child], now: now)
        let rows = sections.flatMap(\.rows)

        let parentIndex = rows.firstIndex { $0.task.id == parent.id }!
        #expect(rows[parentIndex + 1].task.id == child.id)   // child immediately follows
        #expect(rows[parentIndex + 1].indented)
        #expect(!rows[parentIndex].indented)
    }

    @Test("Orphaned children (parent absent) are promoted, not lost")
    func orphanPromotion() {
        let child = TaskItem(title: "Orphan", category: "Personal", parentTaskId: "gone-parent")
        let sections = HomeGrouping.sections(from: [child], now: Date())
        let rows = sections.flatMap(\.rows)
        #expect(rows.count == 1)
        #expect(!rows[0].indented)
    }
}
