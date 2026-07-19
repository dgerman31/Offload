import Foundation
import GRDB

/// Drives the Calendar tab: live tasks from SQLite, calendar events from EventKit for the
/// visible month, and the selected day's merged timeline. Events are fetched a month at a
/// time (padded to cover the grid's leading/trailing days) and re-fetched when the month
/// changes, so scrolling months stays cheap.
@MainActor
@Observable
final class CalendarStore {

    private(set) var tasks: [TaskItem] = []
    private(set) var events: [CalendarEvent] = []
    private(set) var calendarAccess = false
    private(set) var loadingEvents = false

    /// The month whose grid is on screen (any date within it).
    private(set) var visibleMonth: Date
    /// The day the user has tapped into.
    private(set) var selectedDate: Date

    private let db: AppDatabase
    private let reader: any CalendarReading
    private let calendar: Calendar

    init(
        db: AppDatabase = .shared,
        reader: any CalendarReading = EventKitCalendarReader(),
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        self.db = db
        self.reader = reader
        self.calendar = calendar
        self.visibleMonth = now
        self.selectedDate = calendar.startOfDay(for: now)
    }

    // MARK: Derived views

    /// The grid's days (whole weeks covering the visible month).
    var gridDays: [Date] {
        DayTimeline.monthGridDays(for: visibleMonth, calendar: calendar)
    }

    /// Density per day, computed once per render pass rather than per cell.
    var densityByDay: [Date: DayDensity] {
        DayTimeline.density(tasks: tasks, events: events, calendar: calendar)
    }

    /// The selected day's merged, ordered timeline.
    var selectedDayItems: [DayItem] {
        DayTimeline.items(tasks: tasks, events: events, on: selectedDate, calendar: calendar)
    }

    func isInVisibleMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)
    }

    func isSelected(_ day: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: selectedDate)
    }

    func isToday(_ day: Date, now: Date = Date()) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }

    var monthTitle: String {
        let df = DateFormatter()
        df.calendar = calendar
        df.dateFormat = calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .year)
            ? "MMMM" : "MMMM yyyy"
        return df.string(from: visibleMonth)
    }

    /// Localized one-letter weekday headers, rotated to the calendar's first weekday.
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        guard shift > 0, shift < symbols.count else { return symbols }
        return Array(symbols[shift...] + symbols[..<shift])
    }

    // MARK: Actions

    func select(_ day: Date) {
        selectedDate = calendar.startOfDay(for: day)
        Haptics.light()
        // Tapping a day outside the visible month follows it there.
        if !isInVisibleMonth(day) {
            visibleMonth = day
            Task { await loadEvents() }
        }
    }

    func moveMonth(by delta: Int) {
        guard let moved = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        visibleMonth = moved
        Haptics.light()
        Task { await loadEvents() }
    }

    func goToToday(now: Date = Date()) {
        let changedMonth = !calendar.isDate(visibleMonth, equalTo: now, toGranularity: .month)
        visibleMonth = now
        selectedDate = calendar.startOfDay(for: now)
        Haptics.light()
        if changedMonth { Task { await loadEvents() } }
    }

    // MARK: Loading

    /// Stream every non-deleted task; the grid and timeline derive from this one list.
    func observeTasks() async {
        let observation = ValueObservation.tracking { db in
            try TaskItem.filter(Column("deleted") == false).fetchAll(db)
        }
        do {
            for try await fetched in observation.values(in: db.dbQueue) {
                tasks = fetched
            }
        } catch {
            // Observation ended (view dismissed).
        }
    }

    /// Fetch events spanning the visible grid. Safe to call repeatedly.
    func loadEvents() async {
        let days = gridDays
        guard let first = days.first, let last = days.last else { return }
        loadingEvents = true
        defer { loadingEvents = false }

        calendarAccess = await reader.requestAccess()
        guard calendarAccess else {
            events = []
            return
        }
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        events = await reader.events(from: calendar.startOfDay(for: first), to: end)
    }
}
