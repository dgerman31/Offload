import Testing
import Foundation
@testable import Offload

/// The standing picture of the person, and the rules about when the app is allowed to ask for more.
struct LifeBriefTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: 9))!
    }

    private func iso(_ day: Int) -> String {
        ISO8601DateFormatter().string(from: at(day))
    }

    private var started: LifeBrief {
        var brief = LifeBrief()
        brief.who = "Third-year medical student"
        return brief
    }

    // MARK: The prompt block

    @Test("An empty brief adds nothing to the prompt")
    func emptyBriefIsSilent() {
        // A heading with nothing under it would be pure noise competing with the instructions for
        // the model's attention, so a new user's prompt has to stay exactly as clean as before.
        #expect(LifeBrief().promptFragment() == nil)
    }

    @Test("Only the filled-in parts reach the prompt, in reading order")
    func fragmentIsSelective() throws {
        var brief = LifeBrief()
        brief.who = "Third-year medical student"
        brief.avoid = "Never schedule before 8am"
        let fragment = try #require(brief.promptFragment())
        #expect(fragment.contains("Third-year medical student"))
        #expect(fragment.contains("Never schedule before 8am"))
        #expect(!fragment.contains("A normal week"))
        // Who they are comes before what they don't want.
        #expect(fragment.range(of: "Who I am")!.lowerBound < fragment.range(of: "What not to do")!.lowerBound)
    }

    @Test("Observations the app made appear alongside what the user wrote")
    func observationsAreIncluded() {
        var brief = started
        brief.observations = ["Rarely works on Sundays"]
        #expect(brief.promptFragment()?.contains("Rarely works on Sundays") == true)
    }

    // MARK: When to ask

    @Test("A stranger is never interviewed")
    func neverAsksBeforeTheBriefExists() {
        // Asking someone about their week before they've told you anything is a form, not a
        // conversation. The short setup is the way in; this is the way it stays topped up.
        #expect(LifeBriefInterview.next(brief: LifeBrief(), now: at(10), calendar: calendar) == nil)
    }

    @Test("Questions are spaced days apart")
    func spacingIsRespected() {
        var brief = started
        brief.lastAskedAt = iso(10)
        #expect(LifeBriefInterview.next(brief: brief, now: at(11), calendar: calendar) == nil)
        #expect(LifeBriefInterview.next(brief: brief, now: at(20), calendar: calendar) != nil)
    }

    @Test("It asks about a gap, never about something already answered")
    func onlyAsksAboutGaps() throws {
        var brief = started
        brief.workingToward = "Step 1 in May"
        let question = try #require(LifeBriefInterview.next(brief: brief, now: at(10), calendar: calendar))
        #expect(question.field != .workingToward)
        #expect(question.field != .who)
    }

    @Test("A question waved away never comes back")
    func dismissalIsPermanent() throws {
        let brief = started
        let first = try #require(LifeBriefInterview.next(brief: brief, now: at(10), calendar: calendar))
        let after = LifeBriefInterview.recordDismissed(first, in: brief, now: at(10))
        let next = LifeBriefInterview.next(brief: after, now: at(20), calendar: calendar)
        #expect(next?.id != first.id)
    }

    @Test("Merely showing a question starts the clock")
    func askingIsRecordedOnShow() throws {
        // Otherwise an ignored question returns every single morning, which is the nagging this is
        // built to avoid.
        let brief = started
        let question = try #require(LifeBriefInterview.next(brief: brief, now: at(10), calendar: calendar))
        let after = LifeBriefInterview.recordAsked(question, in: brief, now: at(10))
        #expect(LifeBriefInterview.next(brief: after, now: at(11), calendar: calendar) == nil)
        // …and comes back once enough time has passed, since it's still a real gap.
        #expect(LifeBriefInterview.next(brief: after, now: at(20), calendar: calendar)?.id == question.id)
    }

    @Test("An answer lands in the right field and closes the question")
    func answeringFillsTheBrief() throws {
        let brief = started
        let question = try #require(LifeBriefInterview.questions.first { $0.field == .normalWeek })
        let after = LifeBriefInterview.recordAnswered(question, answer: "  Lectures Mon–Thu  ",
                                                      in: brief, now: at(10))
        #expect(after.normalWeek == "Lectures Mon–Thu")
        #expect(after.answeredQuestions.contains(question.id))
        #expect(after.promptFragment()?.contains("Lectures Mon–Thu") == true)
    }

    @Test("Every question in the bank writes to a field it can read back")
    func everyQuestionRoundTrips() {
        for question in LifeBriefInterview.questions {
            let filled = LifeBriefInterview.apply("an answer", to: question.field, in: LifeBrief())
            #expect(LifeBriefInterview.value(of: question.field, in: filled) == "an answer")
            #expect(!question.prompt.isEmpty)
            #expect(!question.placeholder.isEmpty)
        }
        // Ids are what record "already answered", so a duplicate would silently skip a question.
        #expect(Set(LifeBriefInterview.questions.map(\.id)).count == LifeBriefInterview.questions.count)
    }

    // MARK: Storage

    @Test("A brief survives a round trip through storage, and can be forgotten")
    func storageRoundTrip() {
        let defaults = UserDefaults(suiteName: "LifeBriefTests-\(UUID().uuidString)")!
        var brief = LifeBrief()
        brief.who = "Third-year medical student"
        LifeBrief.save(brief, defaults: defaults, now: at(10))

        let loaded = LifeBrief.stored(defaults: defaults)
        #expect(loaded.who == "Third-year medical student")
        #expect(loaded.updatedAt != nil)

        LifeBrief.forget(defaults: defaults)
        #expect(LifeBrief.stored(defaults: defaults).isEmpty)
    }
}
