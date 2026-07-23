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

    @Test("datesInScope returns exactly one day for .day")
    func dayScopeCount() {
        let cal = utcCalendar
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 22))!
        #expect(GymStore.datesInScope(.day(day), now: day, calendar: cal).count == 1)
    }

    @Test("A week planned from its own Sunday returns all seven days")
    func fullWeekWhenNowIsTheWeekStart() {
        let cal = utcCalendar
        // 2026-07-22 is a Wednesday; startOfWeek gives its Sunday (2026-07-19).
        let wednesday = cal.date(from: DateComponents(year: 2026, month: 7, day: 22))!
        let weekStart = GymStore.startOfWeek(wednesday, calendar: cal)
        let week = GymStore.datesInScope(.week(weekStart), now: weekStart, calendar: cal)
        #expect(week.count == 7)
        #expect(cal.component(.weekday, from: week[0]) == 1)   // Sunday
        #expect(cal.component(.weekday, from: week[6]) == 7)   // Saturday
    }

    @Test("A week planned mid-week never reaches backward into days that already happened")
    func weekScopeClipsToToday() {
        let cal = utcCalendar
        // 2026-07-22 is a Wednesday: the week's Sunday (07-19) through Tuesday (07-21) are past.
        let wednesday = cal.date(from: DateComponents(year: 2026, month: 7, day: 22))!
        let weekStart = GymStore.startOfWeek(wednesday, calendar: cal)   // 2026-07-19 (Sun)
        let week = GymStore.datesInScope(.week(weekStart), now: wednesday, calendar: cal)

        // Only Wed–Sat (4 days) — never Sun/Mon/Tue, which are before "now".
        #expect(week.count == 4)
        #expect(GymStore.dateKey(week.first!) == "2026-07-22")
        #expect(GymStore.dateKey(week.last!) == "2026-07-25")
        #expect(!week.contains { $0 < cal.startOfDay(for: wednesday) })
    }

    @Test("Planning a week that's already entirely in the past returns nothing")
    func fullyPastWeekReturnsEmpty() {
        let cal = utcCalendar
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 22))!
        let lastWeekStart = cal.date(byAdding: .day, value: -7, to: GymStore.startOfWeek(now, calendar: cal))!
        #expect(GymStore.datesInScope(.week(lastWeekStart), now: now, calendar: cal).isEmpty)
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

    // MARK: Skip cascades the rest of the week forward a day

    @Test("Skipping a session shifts every later still-planned session forward a day")
    func cascadeShiftsLaterPlannedSessions() {
        let cal = utcCalendar
        let mon = WorkoutSession(title: "Push", date: "2026-07-20")
        let tue = WorkoutSession(title: "Legs", date: "2026-07-21")
        let wed = WorkoutSession(title: "Pull", date: "2026-07-22")
        let all = [mon, tue, wed]

        let shifts = GymStore.cascadeAfterSkip(mon, in: all, calendar: cal)
        let byId = Dictionary(uniqueKeysWithValues: shifts.map { ($0.id, $0.newDate) })

        #expect(byId[tue.id] == "2026-07-22")   // Tue -> Wed
        #expect(byId[wed.id] == "2026-07-23")   // Wed -> Thu
        #expect(byId[mon.id] == nil)            // the skipped session itself never shifts
    }

    @Test("Skipping never shifts an earlier or already-completed/skipped session")
    func cascadeLeavesEarlierAndSettledSessionsAlone() {
        let cal = utcCalendar
        let skipped = WorkoutSession(title: "Legs", date: "2026-07-21")
        let earlier = WorkoutSession(title: "Push", date: "2026-07-20")
        var alreadyDone = WorkoutSession(title: "Pull", date: "2026-07-22")
        alreadyDone.status = "completed"

        let shifts = GymStore.cascadeAfterSkip(skipped, in: [earlier, alreadyDone], calendar: cal)
        #expect(shifts.isEmpty)
    }

    // MARK: Set logging

    @Test("An exercise with a set count is logged once every set is checked off, not before")
    func isLoggedTracksSetCount() {
        var exercise = GymExercise(name: "Squat", sets: 3, reps: "5")
        #expect(exercise.isLogged == false)
        exercise.completedSets = 2
        #expect(exercise.isLogged == false)
        exercise.completedSets = 3
        #expect(exercise.isLogged == true)
    }

    @Test("A set-less item (a hold, a stretch) logs as done the moment it's touched at all")
    func isLoggedWithNoSetCountNeedsOnlyOneTouch() {
        var exercise = GymExercise(name: "Couch stretch", sets: nil, reps: "60 sec", isMobility: true)
        #expect(exercise.isLogged == false)
        exercise.completedSets = 1
        #expect(exercise.isLogged == true)
    }

    // MARK: Weekly consistency

    @Test("weekProgress counts completed against planned-or-completed, ignoring skipped")
    func weekProgressCountsCorrectly() {
        let cal = utcCalendar
        let sunday = cal.date(from: DateComponents(year: 2026, month: 7, day: 19))!
        var done = WorkoutSession(title: "Push", date: "2026-07-20")
        done.status = "completed"
        let planned = WorkoutSession(title: "Legs", date: "2026-07-21")
        var skipped = WorkoutSession(title: "Pull", date: "2026-07-22")
        skipped.status = "skipped"
        let nextWeek = WorkoutSession(title: "Push", date: "2026-07-27")   // outside this week

        let progress = GymStore.weekProgress([done, planned, skipped, nextWeek], weekStart: sunday, calendar: cal)
        #expect(progress.completed == 1)
        #expect(progress.total == 2)   // done + planned; skipped and next week's don't count
    }

    @Test("A week with no sessions at all reports 0 of 0")
    func weekProgressEmptyWeek() {
        let cal = utcCalendar
        let sunday = cal.date(from: DateComponents(year: 2026, month: 7, day: 19))!
        let progress = GymStore.weekProgress([], weekStart: sunday, calendar: cal)
        #expect(progress.completed == 0)
        #expect(progress.total == 0)
    }
}
