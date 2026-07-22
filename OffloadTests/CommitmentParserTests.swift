import Testing
import Foundation
@testable import Offload

/// Feature D: the commitment parser that splits captured recurrence rules into Routine models.
/// Tests the gym/class example from the spec end-to-end, plus edge cases.
struct CommitmentParserTests {

    // MARK: - RRULE parsing

    @Test("Fixed weekly RRULE with BYDAY parses to correct weekdays")
    func fixedWeeklyByday() {
        let parsed = CommitmentParser.parseRRule("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        #expect(parsed.freq == .weekly)
        #expect(parsed.byDay == [2, 4, 6])   // Mon=2, Wed=4, Fri=6
        #expect(parsed.interval == 1)
        #expect(parsed.count == nil)
    }

    @Test("Daily RRULE with no BYDAY")
    func dailyNoByday() {
        let parsed = CommitmentParser.parseRRule("FREQ=DAILY")
        #expect(parsed.freq == .daily)
        #expect(parsed.byDay == nil)
    }

    @Test("Weekly RRULE with COUNT")
    func weeklyWithCount() {
        let parsed = CommitmentParser.parseRRule("FREQ=WEEKLY;COUNT=5")
        #expect(parsed.freq == .weekly)
        #expect(parsed.count == 5)
    }

    @Test("RRULE with RRULE: prefix is handled")
    func rrulePrefix() {
        let parsed = CommitmentParser.parseRRule("RRULE:FREQ=WEEKLY;BYDAY=TU,TH")
        #expect(parsed.byDay == [3, 5])   // Tue=3, Thu=5
    }

    // MARK: - Day abbreviation mapping

    @Test("All iCalendar day abbreviations map correctly")
    func dayAbbreviations() {
        #expect(CommitmentParser.dayAbbrevToWeekday("SU") == 1)
        #expect(CommitmentParser.dayAbbrevToWeekday("MO") == 2)
        #expect(CommitmentParser.dayAbbrevToWeekday("TU") == 3)
        #expect(CommitmentParser.dayAbbrevToWeekday("WE") == 4)
        #expect(CommitmentParser.dayAbbrevToWeekday("TH") == 5)
        #expect(CommitmentParser.dayAbbrevToWeekday("FR") == 6)
        #expect(CommitmentParser.dayAbbrevToWeekday("SA") == 7)
        #expect(CommitmentParser.dayAbbrevToWeekday("XY") == nil)
    }

    // MARK: - Minutes-since-midnight extraction

    @Test("ISO time string extracts correct minutes since midnight")
    func minutesSinceMidnight() {
        #expect(CommitmentParser.minutesSinceMidnight(from: "2026-07-20T14:30") == 870)  // 14*60+30
        #expect(CommitmentParser.minutesSinceMidnight(from: "2026-07-20T09:00") == 540)  // 9*60
        #expect(CommitmentParser.minutesSinceMidnight(from: "2026-07-20T00:00") == nil)   // midnight → no specific time
        #expect(CommitmentParser.minutesSinceMidnight(from: nil) == nil)
    }

    // MARK: - Full parse: fixed commitment (class with specific days + time)

    @Test("Class M–Th 9–12 becomes a fixed routine")
    func fixedClassRoutine() {
        let task = ExtractedTask(
            title: "Practice of Medicine",
            category: "Work",
            priority: "medium",
            contextTags: ["meeting"],
            dueDate: "2026-07-21T09:00",
            recurrenceRule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH",
            effortMinutes: 180,
            subtasks: []
        )
        let capture = ExtractedCapture(summary: nil, tasks: [task], suggestedProject: nil)
        let result = CommitmentParser.parse(capture)

        #expect(result.routines.count == 1)
        #expect(result.remainingTasks.isEmpty)

        let routine = result.routines[0]
        #expect(routine.title == "Practice of Medicine")
        #expect(routine.routineKind == .fixed)
        #expect(routine.weekdayNumbers == [2, 3, 4, 5])  // Mon–Thu
        #expect(routine.startMinute == 540)                // 9:00 AM
        #expect(routine.durationMinutes == 180)            // 3 hours
    }

    // MARK: - Full parse: flexible commitment (gym with count)

    @Test("Gym 5x/week becomes a flexible routine with flex")
    func flexibleGymRoutine() {
        let task = ExtractedTask(
            title: "Gym workout",
            category: "Health",
            priority: "medium",
            contextTags: ["gym"],
            recurrenceRule: "FREQ=WEEKLY;COUNT=5",
            effortMinutes: 45,
            subtasks: []
        )
        let capture = ExtractedCapture(summary: nil, tasks: [task], suggestedProject: nil)
        let result = CommitmentParser.parse(capture)

        #expect(result.routines.count == 1)
        #expect(result.remainingTasks.isEmpty)

        let routine = result.routines[0]
        #expect(routine.title == "Gym workout")
        #expect(routine.routineKind == .flexible)
        #expect(routine.timesPerWeek == 4)   // 5 → (4, flex 1)
        #expect(routine.flex == 1)
        #expect(routine.durationMinutes == 45)
    }

    // MARK: - Mixed capture: some tasks become routines, some stay tasks

    @Test("Mixed capture splits commitments from regular tasks")
    func mixedCapture() {
        let classTask = ExtractedTask(
            title: "Biochemistry lecture",
            category: "Work",
            priority: "medium",
            contextTags: ["meeting"],
            dueDate: "2026-07-22T09:00",
            recurrenceRule: "FREQ=WEEKLY;BYDAY=TU,TH",
            effortMinutes: 120,
            subtasks: []
        )
        let normalTask = ExtractedTask(
            title: "Buy groceries",
            category: "Personal",
            priority: "medium",
            contextTags: ["store"],
            subtasks: ["milk", "eggs"]
        )
        let capture = ExtractedCapture(summary: nil, tasks: [classTask, normalTask])
        let result = CommitmentParser.parse(capture)

        #expect(result.routines.count == 1)
        #expect(result.routines[0].title == "Biochemistry lecture")
        #expect(result.remainingTasks.count == 1)
        #expect(result.remainingTasks[0].title == "Buy groceries")
    }

    // MARK: - Daily routine

    @Test("FREQ=DAILY becomes a fixed routine for all 7 days")
    func dailyRoutine() {
        let task = ExtractedTask(
            title: "Take vitamins",
            category: "Health",
            priority: "low",
            contextTags: ["home"],
            recurrenceRule: "FREQ=DAILY",
            effortMinutes: 5,
            subtasks: []
        )
        let result = CommitmentParser.parse(ExtractedCapture(summary: nil, tasks: [task], suggestedProject: nil))

        #expect(result.routines.count == 1)
        let routine = result.routines[0]
        #expect(routine.routineKind == .fixed)
        #expect(routine.weekdayNumbers == [1, 2, 3, 4, 5, 6, 7])
        #expect(routine.durationMinutes == 5)
    }

    // MARK: - No recurrence → no routine

    @Test("Task without recurrence passes through unchanged")
    func noRecurrence() {
        let task = ExtractedTask(
            title: "Call dentist",
            category: "Health",
            priority: "medium",
            contextTags: ["phone"],
            subtasks: []
        )
        let result = CommitmentParser.parse(ExtractedCapture(summary: nil, tasks: [task], suggestedProject: nil))
        #expect(result.routines.isEmpty)
        #expect(result.remainingTasks.count == 1)
    }

    // MARK: - The spec's flagship example

    @Test("The gym/class example from FUTURE_PLANS produces correct routines")
    func specExample() {
        // "class M–Th 9–12, Tue/Thu 2–5; gym 5x/week ~45min afternoons"
        let classAM = ExtractedTask(
            title: "Class",
            category: "Work",
            priority: "medium",
            contextTags: ["meeting"],
            dueDate: "2026-07-21T09:00",
            recurrenceRule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH",
            effortMinutes: 180,
            subtasks: []
        )
        let classPM = ExtractedTask(
            title: "Afternoon class",
            category: "Work",
            priority: "medium",
            contextTags: ["meeting"],
            dueDate: "2026-07-22T14:00",
            recurrenceRule: "FREQ=WEEKLY;BYDAY=TU,TH",
            effortMinutes: 180,
            subtasks: []
        )
        let gym = ExtractedTask(
            title: "Gym",
            category: "Health",
            priority: "medium",
            contextTags: ["gym"],
            recurrenceRule: "FREQ=WEEKLY;COUNT=5",
            effortMinutes: 45,
            subtasks: []
        )
        let capture = ExtractedCapture(summary: nil, tasks: [classAM, classPM, gym])
        let result = CommitmentParser.parse(capture)

        #expect(result.routines.count == 3)
        #expect(result.remainingTasks.isEmpty)

        // Class AM: fixed, Mon–Thu, 9:00
        let r0 = result.routines[0]
        #expect(r0.routineKind == .fixed)
        #expect(r0.weekdayNumbers == [2, 3, 4, 5])
        #expect(r0.startMinute == 540)

        // Class PM: fixed, Tue+Thu, 14:00
        let r1 = result.routines[1]
        #expect(r1.routineKind == .fixed)
        #expect(r1.weekdayNumbers == [3, 5])
        #expect(r1.startMinute == 840)

        // Gym: flexible, 4–5×/week
        let r2 = result.routines[2]
        #expect(r2.routineKind == .flexible)
        #expect(r2.timesPerWeek == 4)
        #expect(r2.flex == 1)
        #expect(r2.durationMinutes == 45)
    }
}
