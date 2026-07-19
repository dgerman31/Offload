import Testing
import Foundation
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

    /// Embedder that opts out — keeps the pipeline deterministic on CI (no NLEmbedding).
    struct NullEmbedder: TextEmbedding {
        func vector(for text: String) -> [Double]? { nil }
    }

    /// Embedder with a fixed lookup table so specific titles collide (unlike `NullEmbedder`,
    /// which never triggers a candidate). Titles sharing a vector score cosine 1.0.
    struct StubEmbedder: TextEmbedding {
        var table: [String: [Double]]
        func vector(for text: String) -> [Double]? { table[text] }
    }

    /// Fake calendar writer — returns a fixed id without touching EventKit, so appointment
    /// creation is deterministic on CI.
    struct StubCalendarWriter: CalendarWriting {
        var eventId: String?
        func createEvent(title: String, start: Date, durationMinutes: Int?) async -> String? { eventId }
    }

    /// One extracted task with an optional due date — helper for the dedup-blocking tests.
    private func extractedOneTask(title: String, dueDate: String? = nil, priority: String = "medium") -> ExtractedCapture {
        ExtractedCapture(
            summary: title,
            tasks: [
                ExtractedTask(title: title, category: "Personal", priority: priority,
                              contextTags: [], dueDate: dueDate, recurrenceRule: nil,
                              effortMinutes: nil, subtasks: [])
            ],
            suggestedProject: nil
        )
    }

    // MARK: Dedup blocks before save (spec §3.5)

    @Test("prepare surfaces a candidate when an extracted task resembles an existing open task")
    func prepareSurfacesCandidate() async throws {
        let db = try AppDatabase.makeInMemory()
        let existing = TaskItem(title: "Buy milk", category: "Personal", priority: "medium", status: "open")
        try await db.dbQueue.write { try existing.insert($0) }

        let embedder = StubEmbedder(table: ["Buy milk": [1, 0]])
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(extractedOneTask(title: "Buy milk"))),
                                     embedder: embedder)

        let prepared = try await service.prepare(rawInput: "buy milk", inputType: "text")
        #expect(prepared.candidates.count == 1)
        #expect(prepared.candidates.first?.existingTitle == "Buy milk")
        #expect(prepared.candidates.first?.existingTaskId == existing.id)
        // prepare must NOT insert the new task yet — only the pre-existing one is present.
        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        #expect(taskCount == 1)
    }

    @Test("finalize .skip drops the new task and leaves the existing task untouched")
    func finalizeSkip() async throws {
        let db = try AppDatabase.makeInMemory()
        let existing = TaskItem(title: "Buy milk", category: "Personal", priority: "medium", status: "open")
        try await db.dbQueue.write { try existing.insert($0) }

        let embedder = StubEmbedder(table: ["Buy milk": [1, 0]])
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(extractedOneTask(title: "Buy milk"))),
                                     embedder: embedder)

        let prepared = try await service.prepare(rawInput: "buy milk", inputType: "text")
        let candidate = try #require(prepared.candidates.first)
        let outcome = try await service.finalize(prepared, resolutions: [candidate.id: .skip])

        #expect(outcome.addedTasks == 0)
        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        #expect(taskCount == 1) // only the pre-existing task remains
        let refreshed = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: existing.id) }
        #expect(refreshed?.dueDate == nil)
    }

    @Test("finalize .merge drops the new task and backfills the existing task's empty due date")
    func finalizeMerge() async throws {
        let db = try AppDatabase.makeInMemory()
        // Existing task has NO due date — the merge should fill it from the new capture.
        let existing = TaskItem(title: "Buy milk", category: "Personal", priority: "medium", status: "open", dueDate: nil)
        try await db.dbQueue.write { try existing.insert($0) }

        let embedder = StubEmbedder(table: ["Buy milk": [1, 0]])
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(
                                        extractedOneTask(title: "Buy milk", dueDate: "2026-07-20T09:00:00Z", priority: "high"))),
                                     embedder: embedder)

        let prepared = try await service.prepare(rawInput: "buy milk tomorrow morning", inputType: "text")
        let candidate = try #require(prepared.candidates.first)
        let outcome = try await service.finalize(prepared, resolutions: [candidate.id: .merge])

        #expect(outcome.addedTasks == 0)
        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        #expect(taskCount == 1) // new task discarded; only the (updated) existing task
        let refreshed = try await db.dbQueue.read { try TaskItem.fetchOne($0, key: existing.id) }
        #expect(refreshed?.dueDate != nil)   // backfilled
        #expect(refreshed?.priority == "high") // raised from medium
    }

    @Test("finalize .keepBoth inserts the new task alongside the existing one (prior behavior)")
    func finalizeKeepBoth() async throws {
        let db = try AppDatabase.makeInMemory()
        let existing = TaskItem(title: "Buy milk", category: "Personal", priority: "medium", status: "open")
        try await db.dbQueue.write { try existing.insert($0) }

        let embedder = StubEmbedder(table: ["Buy milk": [1, 0]])
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(extractedOneTask(title: "Buy milk"))),
                                     embedder: embedder)

        let prepared = try await service.prepare(rawInput: "buy milk", inputType: "text")
        let candidate = try #require(prepared.candidates.first)
        let outcome = try await service.finalize(prepared, resolutions: [candidate.id: .keepBoth])

        #expect(outcome.addedTasks == 1)
        #expect(outcome.similarWarnings.count == 1)
        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        #expect(taskCount == 2) // both kept
    }

    @Test("process() keeps every candidate (no-UI path preserves prior behavior)")
    func processDefaultsToKeepBoth() async throws {
        let db = try AppDatabase.makeInMemory()
        let existing = TaskItem(title: "Buy milk", category: "Personal", priority: "medium", status: "open")
        try await db.dbQueue.write { try existing.insert($0) }

        let embedder = StubEmbedder(table: ["Buy milk": [1, 0]])
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(extractedOneTask(title: "Buy milk"))),
                                     embedder: embedder)

        let outcome = try await service.process(rawInput: "buy milk", inputType: "text")
        #expect(outcome.addedTasks == 1)
        #expect(outcome.similarWarnings.count == 1)
        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        #expect(taskCount == 2)
    }

    // MARK: Calendar write (punch list #6)

    @Test("An appointment task gets a calendar event id stamped on save")
    func appointmentCreatesCalendarEvent() async throws {
        let db = try AppDatabase.makeInMemory()
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Dentist", category: "Health", priority: "medium",
                                  contextTags: [], dueDate: "2026-07-21T15:00:00Z", recurrenceRule: nil,
                                  effortMinutes: 30, isAppointment: true, subtasks: [])],
            suggestedProject: nil)
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(extracted)),
                                     embedder: NullEmbedder(),
                                     calendarWriter: StubCalendarWriter(eventId: "evt-123"))

        let outcome = try await service.process(rawInput: "dentist at 3pm friday", inputType: "text")
        #expect(outcome.addedTasks == 1)
        let saved = try await db.dbQueue.read { try TaskItem.fetchAll($0).first }
        #expect(saved?.calendarEventId == "evt-123")
    }

    @Test("A non-appointment task never gets a calendar event, even with a due date")
    func todoSkipsCalendar() async throws {
        let db = try AppDatabase.makeInMemory()
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy milk", category: "Personal", priority: "medium",
                                  contextTags: [], dueDate: "2026-07-21T15:00:00Z", recurrenceRule: nil,
                                  effortMinutes: nil, isAppointment: false, subtasks: [])],
            suggestedProject: nil)
        let service = CaptureService(db: db,
                                     extractor: FakeExtractor(result: .success(extracted)),
                                     embedder: NullEmbedder(),
                                     calendarWriter: StubCalendarWriter(eventId: "should-not-be-used"))

        _ = try await service.process(rawInput: "buy milk tomorrow", inputType: "text")
        let saved = try await db.dbQueue.read { try TaskItem.fetchAll($0).first }
        #expect(saved?.calendarEventId == nil)
    }

    @Test("Success persists project + tasks and marks the capture done with instrumentation")
    func success() async throws {
        let db = try AppDatabase.makeInMemory()
        let extracted = ExtractedCapture(
            summary: "trip",
            tasks: [
                ExtractedTask(title: "Book flights", category: "Projects", priority: "high",
                              contextTags: [], dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: []),
                ExtractedTask(title: "Reserve hotel", category: "Projects", priority: "medium",
                              contextTags: [], dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])
            ],
            suggestedProject: "Trip"
        )
        let service = CaptureService(db: db, extractor: FakeExtractor(result: .success(extracted)), embedder: NullEmbedder())

        let outcome = try await service.process(rawInput: "book flights and hotel for the trip", inputType: "text")
        #expect(outcome.addedTasks == 2)
        #expect(outcome.taskTitles == ["Book flights", "Reserve hotel"])
        #expect(outcome.projectTitle == "Trip")

        let taskCount = try await db.dbQueue.read { try TaskItem.fetchCount($0) }
        let projectCount = try await db.dbQueue.read { try Project.fetchCount($0) }
        let capture = try await db.dbQueue.read { try Capture.fetchAll($0).first }
        #expect(taskCount == 2)
        #expect(projectCount == 1)
        #expect(capture?.processingStatus == "done")
        #expect(capture?.modelSource == "foundation")
        #expect(capture?.processingMs != nil)
        #expect(capture?.extractedTaskIds != nil)
    }

    @Test("Failure keeps the raw capture, marks it failed, and persists no tasks")
    func failure() async throws {
        let db = try AppDatabase.makeInMemory()
        let service = CaptureService(db: db, extractor: FakeExtractor(result: .failure(BoomError())), embedder: NullEmbedder())

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
