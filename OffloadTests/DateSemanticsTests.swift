import Testing
import Foundation
@testable import Offload

/// Regression tests for the date/time bugs found on device: tasks captured after midnight
/// being scheduled for 1 AM, "schedule a meeting" becoming a real calendar event, and the
/// planner moving a 1pm lunch to 9am.
struct DateSemanticsTests {

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private func iso(_ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date(day, hour, minute))
    }

    private func extracted(_ title: String, due: String? = nil, isAppointment: Bool = false) -> ExtractedCapture {
        ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: title, category: "Work", priority: "medium",
                                  contextTags: [], dueDate: due, recurrenceRule: nil,
                                  effortMinutes: nil, isAppointment: isAppointment, subtasks: [])],
            suggestedProject: nil)
    }

    // MARK: The 1 AM bug

    @Test("Temporal language is recognised; ordinary sentences aren't")
    func temporalSignal() {
        #expect(CaptureMapper.hasTemporalSignal("call mom tomorrow"))
        #expect(CaptureMapper.hasTemporalSignal("meeting at 3pm"))
        #expect(CaptureMapper.hasTemporalSignal("rent due friday"))
        #expect(CaptureMapper.hasTemporalSignal("finish it by the 14th"))
        // The actual failing capture — no day, no time, anywhere in it.
        #expect(!CaptureMapper.hasTemporalSignal(
            "I want to create a new research project tambe ai, i need to schedule a meeting w dr Bannazadeh and continue reviewing ct scans"))
        #expect(!CaptureMapper.hasTemporalSignal("buy milk"))
    }

    @Test("Temporal words are matched whole — 'am' inside 'tambe' is not a time")
    func temporalSignalWordBoundaries() {
        // These substrings are why the bug happened: "am" in tambe, "now" in known.
        #expect(!CaptureMapper.hasTemporalSignal("research project tambe ai"))
        #expect(!CaptureMapper.hasTemporalSignal("ask about the known issues"))
        #expect(!CaptureMapper.hasTemporalSignal("email the summary"))
        // But real usages still register.
        #expect(CaptureMapper.hasTemporalSignal("call at 9 am"))
        #expect(CaptureMapper.hasTemporalSignal("do it now"))
    }

    @Test("A capture with no timing gets no due date, whatever the model returns")
    func noTimingMeansNoDate() {
        // Model hallucinates 1 AM because it was told "now" is 12:48 AM.
        let result = CaptureMapper.map(
            extracted("Schedule a meeting with Dr. Bannazadeh", due: iso(20, 1)),
            now: date(20, 0, 48),
            calendar: utcCalendar,
            sourceText: "i need to schedule a meeting w dr Bannazadeh"
        )
        #expect(result.tasks[0].dueDate == nil)
    }

    @Test("A stated day survives, but never as a fake midnight time")
    func statedDayStaysADay() {
        let result = CaptureMapper.map(
            extracted("Pay rent", due: iso(24, 0)),
            now: date(20, 10), calendar: utcCalendar,
            sourceText: "rent is due friday"
        )
        #expect(result.tasks[0].dueDate != nil)
        #expect(result.tasks[0].dueIsAllDay)          // a day, not a moment
        #expect(!result.tasks[0].hasSpecificTime)
    }

    @Test("A stated time is kept exactly as a commitment")
    func statedTimeIsKept() {
        let result = CaptureMapper.map(
            extracted("Lunch with Sam", due: iso(20, 13)),
            now: date(20, 10), calendar: utcCalendar,
            sourceText: "lunch with sam at 1pm"
        )
        #expect(result.tasks[0].hasSpecificTime)
        #expect(DueDate.parse(result.tasks[0].dueDate) == date(20, 13))
    }

    @Test("Times in the small hours are demoted to whole-day, never scheduled")
    func noNightScheduling() {
        #expect(CaptureMapper.isSleepingHour(date(20, 1), calendar: utcCalendar))
        #expect(CaptureMapper.isSleepingHour(date(20, 23), calendar: utcCalendar))
        #expect(!CaptureMapper.isSleepingHour(date(20, 9), calendar: utcCalendar))

        // Even with real timing language, 2 AM isn't a plan.
        let result = CaptureMapper.map(
            extracted("Review CT scans", due: iso(20, 2)),
            now: date(20, 0, 48), calendar: utcCalendar,
            sourceText: "review ct scans tomorrow"
        )
        #expect(result.tasks[0].dueIsAllDay)
    }

    // MARK: Timezone — "tomorrow 2pm" must stay 2pm local

    private var estCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    @Test("A model time with a stray Z is read as local wall-clock, not UTC")
    func modelTimeIsLocalNotUTC() {
        // The model meant 2pm but appended Z. In America/New_York that must be 2pm local — the
        // old behaviour treated it as UTC and showed 10am (the exact bug reported).
        let parsed = DueDate.parseLocal("2026-07-21T14:00:00Z", timeZone: estCalendar.timeZone)
        let hour = parsed.map { estCalendar.component(.hour, from: $0) }
        #expect(hour == 14)
    }

    @Test("End to end: 'tomorrow at 2pm' resolves to 2pm the next local day")
    func tomorrowAtTwoResolvesLocally() {
        let now = estCalendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 21))!  // Mon 9pm
        // Model returns the 21st at 14:00 with a stray Z.
        let extracted = ExtractedCapture(
            summary: nil,
            tasks: [ExtractedTask(title: "Do the thing", category: "Work", priority: "medium",
                                  contextTags: [], dueDate: "2026-07-21T14:00:00Z", recurrenceRule: nil,
                                  effortMinutes: nil, subtasks: [])],
            suggestedProject: nil)
        let result = CaptureMapper.map(extracted, now: now, calendar: estCalendar,
                                       sourceText: "do the thing tomorrow at 2pm")
        let due = DueDate.parse(result.tasks[0].dueDate)
        #expect(due != nil)
        #expect(result.tasks[0].hasSpecificTime)                       // a real time, not all-day
        #expect(due.map { estCalendar.component(.hour, from: $0) } == 14)   // 2pm local, not 10am
        #expect(due.map { estCalendar.component(.day, from: $0) } == 21)    // tomorrow, not 2 days out
    }

    // MARK: The phantom calendar event

    @Test("A task about arranging a meeting is never a calendar event")
    func arrangingIsNotAnAppointment() {
        #expect(!CaptureMapper.isRealAppointment(
            title: "Schedule a meeting with Dr. Bannazadeh",
            isAppointment: true, dueDate: iso(20, 13), isAllDay: false))
        #expect(!CaptureMapper.isRealAppointment(
            title: "Book the dentist", isAppointment: true, dueDate: iso(20, 13), isAllDay: false))
        #expect(!CaptureMapper.isRealAppointment(
            title: "Find a time with Sarah", isAppointment: true, dueDate: iso(20, 13), isAllDay: false))
    }

    @Test("A genuine appointment with a real time still becomes an event")
    func realAppointmentAccepted() {
        #expect(CaptureMapper.isRealAppointment(
            title: "Dentist checkup", isAppointment: true, dueDate: iso(21, 15), isAllDay: false))
    }

    @Test("An appointment without a real time is refused — the calendar needs certainty")
    func appointmentNeedsATime() {
        #expect(!CaptureMapper.isRealAppointment(
            title: "Dentist checkup", isAppointment: true, dueDate: iso(21, 0), isAllDay: true))
        #expect(!CaptureMapper.isRealAppointment(
            title: "Dentist checkup", isAppointment: true, dueDate: nil, isAllDay: false))
    }

    @Test("End to end: the failing capture produces no event and no invented time")
    func failingCaptureEndToEnd() {
        let result = CaptureMapper.map(
            extracted("Schedule a meeting with Dr. Bannazadeh", due: iso(20, 1), isAppointment: true),
            now: date(20, 0, 48), calendar: utcCalendar,
            sourceText: "i need to schedule a meeting w dr Bannazadeh and continue reviewing ct scans"
        )
        #expect(result.appointmentTaskIds.isEmpty)   // nothing written to the real calendar
        #expect(result.tasks[0].dueDate == nil)      // and no 1 AM
    }

    // MARK: The planner moving a committed lunch

    @Test("A pinned time is never rescheduled by the planner")
    func committedTimeIsNotMoved() {
        // Pinned = a commitment the user made. Without the pin it'd be soft and reflowable.
        var lunch = TaskItem(title: "Lunch", dueDate: iso(20, 13))
        lunch.dueIsAllDay = false
        lunch.pinned = true

        let candidates = DayPlanner.candidates(
            from: [lunch, TaskItem(title: "Loose task")],
            on: date(20), now: date(20, 9), calendar: utcCalendar
        )
        #expect(candidates.map(\.title) == ["Loose task"])   // lunch is a constraint, not a candidate
    }

    @Test("Pinned tasks block time so other work is planned around them")
    func committedTasksBlockTime() {
        var lunch = TaskItem(title: "Lunch", dueDate: iso(20, 13), effortMinutes: 60)
        lunch.dueIsAllDay = false
        lunch.pinned = true

        let blocks = DayPlanner.busyBlocks(from: [lunch], on: date(20), calendar: utcCalendar)
        #expect(blocks.count == 1)
        #expect(blocks[0].start == date(20, 13))
        #expect(blocks[0].end == date(20, 14))

        // Planning a long task must not land on top of it.
        let plan = DayPlanner.plan(
            tasks: [lunch, TaskItem(title: "Deep work", priority: "high", effortMinutes: 120)],
            events: [], on: date(20), now: date(20, 12),
            calendar: utcCalendar, dayStartHour: 9, dayEndHour: 18
        )
        for scheduled in plan.scheduled {
            let overlaps = scheduled.start < date(20, 14) && scheduled.end > date(20, 13)
            #expect(!overlaps)
        }
    }

    @Test("Whole-day tasks stay flexible and can be planned")
    func allDayTasksArePlannable() {
        var flexible = TaskItem(title: "Write report", dueDate: iso(20, 0))
        flexible.dueIsAllDay = true

        let candidates = DayPlanner.candidates(from: [flexible], on: date(20), now: date(20, 9),
                                               calendar: utcCalendar)
        #expect(candidates.map(\.title) == ["Write report"])
    }

    @Test("The day is planned to about two thirds, not packed solid")
    func doesNotOverfillTheDay() {
        // Eight hours free, twelve hours of work offered.
        let tasks = (1...12).map { TaskItem(title: "T\($0)", effortMinutes: 60) }
        let plan = DayPlanner.plan(tasks: tasks, events: [], on: date(20), now: date(20, 8),
                                   calendar: utcCalendar, dayStartHour: 9, dayEndHour: 17)
        let planned = plan.scheduled.reduce(0) { $0 + $1.minutes }
        #expect(planned <= Int(Double(plan.freeMinutes) * DayPlanner.planningRatio) + 60)
        #expect(!plan.unplaced.isEmpty)      // and it's honest about the rest
    }

    // MARK: Display

    @Test("A whole-day task never displays a midnight clock time")
    func allDayDisplay() {
        let text = TaskRowView.formatDue(iso(20, 0), allDay: true)
        #expect(!text.contains("12:00"))
        #expect(!text.contains("AM"))
    }

    @Test("A task's own calendar event isn't shown twice on the timeline")
    func noDuplicateEvent() {
        var task = TaskItem(title: "Dentist", dueDate: iso(20, 15))
        task.calendarEventId = "evt-1"
        let event = CalendarEvent(id: "evt-1", title: "Dentist", start: date(20, 15),
                                  end: date(20, 16), isAllDay: false, location: nil, colorHex: nil)

        let items = DayTimeline.items(tasks: [task], events: [event], on: date(20), calendar: utcCalendar)
        #expect(items.count == 1)
        #expect(!items[0].isEvent)      // the task survives — it's the thing you can tick off
    }
}
