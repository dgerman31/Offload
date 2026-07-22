import Testing
import Foundation
import GRDB
@testable import Offload

/// The quick-tap refinement chips: parsing the model's wire form, the deterministic per-task
/// patch each chip applies, and end-to-end application through the capture pipeline.
@MainActor
struct ChipTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func date(_ day: Int, _ hour: Int = 9) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    // MARK: Parsing — unknown actions are dropped, not trusted

    @Test("Known action keys parse; an unknown key is rejected")
    func actionParsing() {
        #expect(ChipAction.parse(key: "due_tomorrow", value: nil) == .dueTomorrow)
        #expect(ChipAction.parse(key: "priority_high", value: nil) == .bumpPriorityHigh)
        #expect(ChipAction.parse(key: "set_category", value: "Health") == .setCategory("Health"))
        #expect(ChipAction.parse(key: "assign_project", value: "Website") == .assignProject("Website"))
        // The current prompt/schema spell these "due_none" and "repeat_weekly"; the older
        // "due_clear"/"recur_weekly" spellings still parse so nothing breaks in flight.
        #expect(ChipAction.parse(key: "due_none", value: nil) == .clearDue)
        #expect(ChipAction.parse(key: "due_clear", value: nil) == .clearDue)
        #expect(ChipAction.parse(key: "repeat_weekly", value: nil) == .recurWeekly)
        #expect(ChipAction.parse(key: "recur_weekly", value: nil) == .recurWeekly)
        // A value-requiring action with no value, and an unknown key, both fail closed.
        #expect(ChipAction.parse(key: "set_category", value: nil) == nil)
        #expect(ChipAction.parse(key: "make_coffee", value: nil) == nil)
    }

    @Test("Chip groups cluster the mutually-exclusive due-date options together")
    func groups() {
        #expect(ChipAction.dueToday.group == "due")
        #expect(ChipAction.clearDue.group == "due")
        #expect(ChipAction.bumpPriorityHigh.group == "priority")
        #expect(ChipAction.recurWeekly.group == "recurrence")
    }

    // MARK: Deterministic patches

    @Test("Due-date chips set a whole-day intention; clear removes it")
    func dueChips() {
        let base = TaskItem(title: "Thing")
        let tomorrow = ClarifyChip(label: "Tomorrow", action: .dueTomorrow)
            .patch(base, now: date(20), calendar: utcCalendar)
        #expect(tomorrow.dueIsAllDay)
        #expect(DueDate.parse(tomorrow.dueDate).map { utcCalendar.component(.day, from: $0) } == 21)
        #expect(!tomorrow.hasSpecificTime)   // a day, not a clock time

        var dated = base
        dated.dueDate = DueDate.canonicalString(from: date(20))
        let cleared = ClarifyChip(label: "No date", action: .clearDue).patch(dated, now: date(20), calendar: utcCalendar)
        #expect(cleared.dueDate == nil)
        #expect(!cleared.dueIsAllDay)
    }

    @Test("Priority, recurrence, and category chips patch just their field")
    func fieldChips() {
        let base = TaskItem(title: "Thing", category: "Work")
        #expect(ClarifyChip(label: "High", action: .bumpPriorityHigh).patch(base).priority == "high")
        #expect(ClarifyChip(label: "Weekly", action: .recurWeekly).patch(base).recurrenceRule == "FREQ=WEEKLY")
        #expect(ClarifyChip(label: "Health", action: .setCategory("Health")).patch(base).category == "Health")
        // An off-list category still normalizes to Other (data-integrity rail kept).
        #expect(ClarifyChip(label: "Nonsense", action: .setCategory("Zorp")).patch(base).category == "Other")
    }

    // MARK: End to end through the pipeline

    @Test("Chips ride the outcome and a tap patches the saved task")
    func chipAppliesEndToEnd() async throws {
        let db = try AppDatabase.makeInMemory()
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Call the clinic", category: "Health", priority: "medium",
                                  contextTags: [], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: [])],
            suggestedProject: nil)
        let chip = ClarifyChip(label: "Tomorrow", action: .dueTomorrow)
        let service = CaptureService(
            db: db,
            extractor: CaptureServiceTests.FakeExtractor(result: .success(extracted), chips: [chip]),
            embedder: CaptureServiceTests.NullEmbedder())

        let outcome = try await service.process(rawInput: "call the clinic", inputType: "text")
        #expect(outcome.chips.count == 1)                       // the chip travelled with the outcome
        #expect(outcome.insertedTaskIds.count == 1)

        await service.applyChip(chip, toTaskIds: outcome.insertedTaskIds, now: date(20))
        let saved = try await db.dbQueue.read { try TaskItem.fetchAll($0).first }
        #expect(saved?.dueDate != nil)                          // now dated
        #expect(saved?.dueIsAllDay == true)
    }

    @Test("An assign-project chip creates and links a container")
    func assignProjectChip() async throws {
        let db = try AppDatabase.makeInMemory()
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Buy paint", category: "Personal", priority: "medium",
                                  contextTags: [], dueDate: nil, recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: [])],
            suggestedProject: nil)
        let chip = ClarifyChip(label: "Add to Reno", action: .assignProject("Home Reno"))
        let service = CaptureService(
            db: db,
            extractor: CaptureServiceTests.FakeExtractor(result: .success(extracted), chips: [chip]),
            embedder: CaptureServiceTests.NullEmbedder())

        let outcome = try await service.process(rawInput: "buy paint", inputType: "text")
        await service.applyChip(chip, toTaskIds: outcome.insertedTaskIds)

        let project = try await db.dbQueue.read { try Project.fetchAll($0).first }
        let task = try await db.dbQueue.read { try TaskItem.fetchAll($0).first }
        #expect(project?.title == "Home Reno")
        #expect(task?.projectId == project?.id)
    }
}
