import Testing
import GRDB
@testable import Offload

@MainActor
struct CaptureServiceTests {

    /// Stand-in for the on-device model so the pipeline is testable without inference.
    struct FakeExtractor: TaskExtracting {
        var result: Result<ExtractedCapture, any Error>
        func extract(from transcript: String) async throws -> ExtractedCapture {
            try result.get()
        }
    }
    struct BoomError: Error {}

    @Test("Success persists project + tasks and marks the capture done with instrumentation")
    func success() async throws {
        let db = try AppDatabase.makeInMemory()
        let extracted = ExtractedCapture(
            summary: "trip",
            tasks: [ExtractedTask(title: "Book flights", category: "Projects", priority: "high",
                                  contextTags: [], dueDate: nil, recurrenceRule: nil, effortMinutes: nil)],
            suggestedProject: "Trip"
        )
        let service = CaptureService(db: db, extractor: FakeExtractor(result: .success(extracted)))

        let outcome = try await service.process(rawInput: "book flights for the trip", inputType: "text")
        #expect(outcome.addedTasks == 1)
        #expect(outcome.projectTitle == "Trip")

        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        let projectCount = try await db.dbQueue.read { try Project.fetchCount($0) }
        let capture = try await db.dbQueue.read { try Capture.fetchAll($0).first }
        #expect(taskCount == 1)
        #expect(projectCount == 1)
        #expect(capture?.processingStatus == "done")
        #expect(capture?.modelSource == "foundation")
        #expect(capture?.processingMs != nil)
        #expect(capture?.extractedTaskIds != nil)
    }

    @Test("Failure keeps the raw capture, marks it failed, and persists no tasks")
    func failure() async throws {
        let db = try AppDatabase.makeInMemory()
        let service = CaptureService(db: db, extractor: FakeExtractor(result: .failure(BoomError())))

        await #expect(throws: BoomError.self) {
            _ = try await service.process(rawInput: "remember the milk", inputType: "text")
        }

        let capture = try await db.dbQueue.read { try Capture.fetchAll($0).first }
        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        #expect(capture?.processingStatus == "failed")
        #expect(capture?.rawInput == "remember the milk")
        #expect(taskCount == 0)
    }
}
