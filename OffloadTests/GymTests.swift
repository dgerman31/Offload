import Testing
import Foundation
@testable import Offload

/// The Gym tab: workout sessions, date-scope helpers, and the rule that ties a session to its
/// schedule-blocking task — including the cascade that keeps them consistent when either side
/// is deleted from a different screen.
struct GymTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    // MARK: WorkoutSession JSON round-trip

    @Test("Muscle groups and exercises round-trip through their JSON columns")
    func sessionRoundTrip() {
        let exercises = [
            GymExercise(name: "Bench Press", sets: 4, reps: "6-8", weightNote: "add 5lb", restSeconds: 120, isMobility: false),
            GymExercise(name: "Shoulder circles", sets: nil, reps: "30 sec", isMobility: true)
        ]
        let session = WorkoutSession(title: "Push Day", date: "2026-07-22",
                                     muscleGroups: ["Chest", "Shoulders", "Triceps"], exercises: exercises)

        #expect(session.muscleGroupList == ["Chest", "Shoulders", "Triceps"])
        #expect(session.exerciseList.count == 2)
        #expect(session.exerciseList[0].name == "Bench Press")
        #expect(session.exerciseList[0].sets == 4)
        #expect(session.exerciseList[1].isMobility == true)
    }

    @Test("A session with no exercises or groups decodes to empty, not a crash")
    func emptySessionDecodesCleanly() {
        let session = WorkoutSession(title: "Rest", date: "2026-07-23")
        #expect(session.muscleGroupList.isEmpty)
        #expect(session.exerciseList.isEmpty)
    }

    // MARK: Date-scope helpers

    @Test("startOfWeek always lands on a Sunday, regardless of the input weekday")
    func startOfWeekIsSunday() {
        let cal = utcCalendar
        for day in 1...7 {
            let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 12 + day))!
            let sunday = GymStore.startOfWeek(date, calendar: cal)
            #expect(cal.component(.weekday, from: sunday) == 1)
            #expect(sunday <= date)
        }
    }

    @Test("datesInScope returns exactly one day for .day and seven for .week")
    func scopeDateCounts() {
        let cal = utcCalendar
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 22))!
        #expect(GymStore.datesInScope(.day(day), now: day, calendar: cal).count == 1)

        let weekStart = GymStore.startOfWeek(day, calendar: cal)
        let week = GymStore.datesInScope(.week(weekStart), now: day, calendar: cal)
        #expect(week.count == 7)
        #expect(cal.component(.weekday, from: week[0]) == 1)   // Sunday
        #expect(cal.component(.weekday, from: week[6]) == 7)   // Saturday
    }

    @Test("dateKey formats as yyyy-MM-dd regardless of time-of-day")
    func dateKeyFormat() {
        let cal = utcCalendar
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 23, minute: 45))!
        #expect(GymStore.dateKey(date) == "2026-07-22")
    }

    // MARK: Cascade delete — the app's one integration point with the Gym tab

    @Test("Deleting a gym-linked task from Home/Day also marks its workout session deleted")
    func deletingTaskCascadesToSession() async throws {
        let db = try AppDatabase.makeInMemory()
        let session = WorkoutSession(title: "Leg Day", date: "2026-07-22")
        let task = TaskItem(title: "Leg Day", category: "Health", gymSessionId: session.id)

        try await db.dbQueue.write { database in
            try session.insert(database)
            try task.insert(database)
        }

        await TaskActions.delete(task, db: db)

        let reloaded = try await db.dbQueue.read { database in
            try WorkoutSession.fetchOne(database, key: session.id)
        }
        #expect(reloaded?.deleted == true)
    }

    @Test("Deleting an ordinary task never touches workout_sessions")
    func ordinaryDeleteLeavesGymAlone() async throws {
        let db = try AppDatabase.makeInMemory()
        let session = WorkoutSession(title: "Leg Day", date: "2026-07-22")
        let unrelated = TaskItem(title: "Email advisor")

        try await db.dbQueue.write { database in
            try session.insert(database)
            try unrelated.insert(database)
        }

        await TaskActions.delete(unrelated, db: db)

        let reloaded = try await db.dbQueue.read { database in
            try WorkoutSession.fetchOne(database, key: session.id)
        }
        #expect(reloaded?.deleted == false)
    }
}
