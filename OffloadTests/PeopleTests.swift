import Testing
import Foundation
@testable import Offload

/// Relationship tracking: who a task involves, and what's outstanding with each person.
struct PeopleTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: 9))!
    }

    private func iso(_ day: Int) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day))
    }

    private func task(_ title: String, people: [String], due: String? = nil, done: Bool = false) -> TaskItem {
        var t = TaskItem(title: title, dueDate: due, people: People.encode(people))
        if done { t.status = "completed" }
        return t
    }

    // MARK: Encoding

    @Test("Names round-trip through JSON storage")
    func roundTrip() {
        let encoded = People.encode(["Sarah", "Dr. Patel"])
        #expect(People.decode(encoded) == ["Sarah", "Dr. Patel"])
    }

    @Test("Duplicates collapse case-insensitively — one person, not three")
    func deduplicates() {
        #expect(People.decode(People.encode(["Sarah", "sarah", "SARAH"])) == ["Sarah"])
    }

    @Test("Junk names are dropped and the list is capped")
    func filtersJunk() {
        #expect(People.encode(["a", " ", ""]) == nil)          // too short to be a name
        #expect(People.encode([]) == nil)
        let many = (1...12).map { "Person\($0)" }
        #expect(People.decode(People.encode(many)).count == 5) // capped
    }

    @Test("Malformed stored JSON decodes to nothing rather than crashing")
    func malformed() {
        #expect(People.decode("not json").isEmpty)
        #expect(People.decode(nil).isEmpty)
    }

    // MARK: Commitments

    @Test("Open work groups by person, busiest first")
    func grouping() {
        let tasks = [
            task("Send deck", people: ["Sarah"]),
            task("Reply to email", people: ["Sarah"]),
            task("Call back", people: ["Tom"])
        ]
        let commitments = People.commitments(from: tasks, now: date(18), calendar: utcCalendar)

        #expect(commitments.count == 2)
        #expect(commitments[0].name == "Sarah")     // two open beats one
        #expect(commitments[0].open.count == 2)
        #expect(commitments[1].name == "Tom")
    }

    @Test("Overdue obligations sort above merely numerous ones")
    func overdueSortsFirst() {
        let tasks = [
            task("A", people: ["Sarah"]), task("B", people: ["Sarah"]), task("C", people: ["Sarah"]),
            task("Owed ages ago", people: ["Tom"], due: iso(10))
        ]
        let commitments = People.commitments(from: tasks, now: date(18), calendar: utcCalendar)
        #expect(commitments[0].name == "Tom")       // one overdue outranks three pending
        #expect(commitments[0].overdueCount == 1)
    }

    @Test("A met obligation stops being owed")
    func completedDropOut() {
        let tasks = [
            task("Sent it", people: ["Sarah"], done: true),
            task("Still owe this", people: ["Sarah"])
        ]
        let commitments = People.commitments(from: tasks, now: date(18), calendar: utcCalendar)
        #expect(commitments.count == 1)
        #expect(commitments[0].open.count == 1)
        #expect(commitments[0].open[0].title == "Still owe this")
    }

    @Test("One task can be owed to several people")
    func sharedTask() {
        let tasks = [task("Send the invite", people: ["Sarah", "Tom"])]
        let commitments = People.commitments(from: tasks, now: date(18), calendar: utcCalendar)
        #expect(commitments.count == 2)
        #expect(commitments.allSatisfy { $0.open.count == 1 })
    }

    @Test("Tasks with nobody attached create no commitments")
    func noPeople() {
        let tasks = [TaskItem(title: "Buy milk")]
        #expect(People.commitments(from: tasks, now: date(18), calendar: utcCalendar).isEmpty)
    }

    @Test("Summary states what's open and flags overdue")
    func summary() {
        let commitment = People.Commitment(name: "Sarah", open: [TaskItem(title: "A")], overdueCount: 1)
        let text = People.summary(for: commitment)
        #expect(text.contains("1 open"))
        #expect(text.contains("overdue"))
    }
}
