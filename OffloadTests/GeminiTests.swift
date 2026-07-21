import Testing
import Foundation
@testable import Offload

/// The pure, testable parts of the Gemini layer: schema encoding, response parsing, and the
/// rate-limiter that keeps us inside the free tier. The network call itself is exercised on
/// device (CI has no key or connectivity).
struct GeminiTests {

    // MARK: Schema encoding

    @Test("A schema encodes to Gemini's OpenAPI-subset shape")
    func schemaEncoding() {
        let schema: GSchema = .object(properties: [
            ("title", .string()),
            ("priority", .string(enumValues: ["high", "low"])),
            ("count", .integer(nullable: true)),
            ("tags", .array(.string()))
        ], required: ["title"])

        let json = schema.json
        #expect(json["type"] as? String == "OBJECT")
        let props = json["properties"] as? [String: Any]
        #expect((props?["title"] as? [String: Any])?["type"] as? String == "STRING")
        // Enum fields carry their allowed values.
        #expect(((props?["priority"] as? [String: Any])?["enum"] as? [String]) == ["high", "low"])
        // Nullable is marked.
        #expect((props?["count"] as? [String: Any])?["nullable"] as? Bool == true)
        // Arrays describe their items.
        let tags = props?["tags"] as? [String: Any]
        #expect(tags?["type"] as? String == "ARRAY")
        #expect((tags?["items"] as? [String: Any])?["type"] as? String == "STRING")
        // Required + a stable property order are emitted.
        #expect((json["required"] as? [String]) == ["title"])
        #expect((json["propertyOrdering"] as? [String]) == ["title", "priority", "count", "tags"])
    }

    // MARK: Response parsing

    @Test("The generated text is pulled from the candidates envelope")
    func extractText() throws {
        let body = """
        {"candidates":[{"content":{"parts":[{"text":"{\\"tasks\\":[]}"}]},"finishReason":"STOP"}]}
        """
        let text = try GeminiClient.extractText(from: Data(body.utf8))
        #expect(text == "{\"tasks\":[]}")
    }

    @Test("A safety block is surfaced as an error, not silent emptiness")
    func blockedResponse() {
        let body = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        #expect(throws: GeminiError.self) {
            _ = try GeminiClient.extractText(from: Data(body.utf8))
        }
    }

    @Test("An empty candidate list throws rather than returning junk")
    func emptyResponse() {
        #expect(throws: GeminiError.self) {
            _ = try GeminiClient.extractText(from: Data(#"{"candidates":[]}"#.utf8))
        }
    }

    @Test("An API error message is extracted for display")
    func errorMessage() {
        let body = #"{"error":{"code":400,"message":"API key not valid"}}"#
        #expect(GeminiClient.errorMessage(from: Data(body.utf8)) == "API key not valid")
    }

    // MARK: Budget

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "aibudget-\(UUID().uuidString)")!
    }

    @Test("The per-minute ceiling is enforced, then the window slides")
    func perMinuteLimit() async {
        let budget = AIBudget(defaults: freshDefaults())
        let base = Date()
        // Fill the minute.
        for i in 0..<AIBudget.maxPerMinute {
            #expect(await budget.reserve(now: base.addingTimeInterval(Double(i))) == true)
        }
        // One more within the minute is refused.
        #expect(await budget.reserve(now: base.addingTimeInterval(30)) == false)
        // A minute later, room again.
        #expect(await budget.reserve(now: base.addingTimeInterval(61)) == true)
    }

    @Test("The per-day ceiling is enforced across minutes")
    func perDayLimit() async {
        let budget = AIBudget(defaults: freshDefaults())
        let base = Date()
        // Spread requests across many minutes so only the daily cap can stop them.
        var granted = 0
        for i in 0..<(AIBudget.maxPerDay + 5) {
            if await budget.reserve(now: base.addingTimeInterval(Double(i) * 61)) { granted += 1 }
        }
        #expect(granted == AIBudget.maxPerDay)
    }

    @Test("A refund returns the reservation to the budget")
    func refund() async {
        let defaults = freshDefaults()
        let budget = AIBudget(defaults: defaults)
        let now = Date()
        #expect(await budget.reserve(now: now) == true)
        #expect(await budget.usedToday(now: now) == 1)
        await budget.refund(now: now)
        #expect(await budget.usedToday(now: now) == 0)
    }

    // MARK: Planner ordering

    @Test("A preferred order reorders the plan; unranked tasks keep their place")
    func preferredOrderReorders() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let now = c.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 8))!
        let day = now

        let a = TaskItem(title: "A", effortMinutes: 30)
        let b = TaskItem(title: "B", effortMinutes: 30)
        let cc = TaskItem(title: "C", effortMinutes: 30)

        // Ask for C, then A first.
        let plan = DayPlanner.plan(
            tasks: [a, b, cc], events: [], on: day, now: now,
            calendar: c, dayStartHour: 8, dayEndHour: 18,
            preferredOrder: [cc.id, a.id]
        )
        #expect(plan.scheduled.first?.task.title == "C")
        #expect(plan.scheduled.map(\.task.title) == ["C", "A", "B"])   // B unranked, stays last
    }
}
