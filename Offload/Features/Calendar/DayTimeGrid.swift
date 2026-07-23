import SwiftUI

/// What `DayTimeGrid` needs from an entry to position, size, and (maybe) drag it.
protocol DayGridEntry: Identifiable {
    var start: Date { get }
    var end: Date { get }
    /// Any task can be dragged to any slot, including a Gym-linked or otherwise pinned one —
    /// only a real calendar event (not under this app's control to reschedule) can't be.
    var isDraggable: Bool { get }
}

/// A real time-grid for one day's timed items: gridlines every 30 minutes (only the on-the-hour
/// ones carry a printed label) across the app's day-start/end window, with each entry positioned
/// and sized by its actual time instead of stacked in a list. Any task can be long-pressed and
/// dragged to any 15-minute-aligned point on the grid, including empty space — something native
/// `.draggable`/`.dropDestination` can't do (there's no discrete view to drop *onto*; the target
/// here is an arbitrary point on a continuous canvas), so this is a deliberate, scoped exception
/// to preferring native gesture primitives elsewhere in the app. The long-press gate (nothing
/// happens on a plain vertical swipe) is what keeps this from fighting the page's own scrolling,
/// the same reasoning `SwipeToDeleteModifier` uses for its own `.simultaneousGesture`.
struct DayTimeGrid<Entry: DayGridEntry, RowContent: View>: View {
    var entries: [Entry]
    var dayStartHour: Int
    var dayEndHour: Int
    var day: Date
    var calendar: Calendar = .current
    /// Called with the snapped `Date` a dragged entry was released at.
    var onReschedule: (Entry, Date) -> Void
    @ViewBuilder var rowContent: (Entry) -> RowContent

    /// Taller than a typical calendar app's default zoom, deliberately — more vertical room per
    /// hour so a block's own title/time text has space to breathe, at the cost of scrolling
    /// further to see the whole day.
    static var hourHeight: CGFloat { 100 }
    private var pointsPerMinute: CGFloat { Self.hourHeight / 60 }
    /// A block never renders shorter than this, so even a 15-minute task stays legible.
    private static var minimumBlockHeight: CGFloat { 32 }
    private static var gutterWidth: CGFloat { 54 }

    @State private var draggingID: Entry.ID?
    @State private var liveSnappedStart: Date?

    private var windowStart: Date {
        calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: day) ?? day
    }
    private var windowEnd: Date {
        calendar.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: day) ?? day
    }
    private var totalMinutes: Int {
        max(60, Int(windowEnd.timeIntervalSince(windowStart) / 60))
    }
    private var totalHeight: CGFloat { CGFloat(totalMinutes) * pointsPerMinute }
    /// Only on-the-hour marks get a printed label — a half-hour still gets a lighter tick line
    /// for rhythm, just no text, so the gutter doesn't turn into a wall of numbers.
    private var hourMarks: [Int] { Array(stride(from: 0, to: totalMinutes, by: 60)) }
    private var halfHourOnlyMarks: [Int] { Array(stride(from: 30, to: totalMinutes, by: 60)) }

    private func y(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }
    private func y(atMinute minute: Int) -> CGFloat { CGFloat(minute) * pointsPerMinute }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Labels and gridlines both derive their Y from the exact same `y(atMinute:)`, in
            // separate same-height columns, so a label and its line can never drift apart —
            // the previous version stacked them independently (a `VStack` of per-half-hour
            // frames for each), which is what actually caused them not to line up.
            ZStack(alignment: .topTrailing) {
                ForEach(hourMarks, id: \.self) { minute in
                    Text(Self.label(windowStart, addingMinutes: minute, calendar: calendar))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Offload.muted)
                        .fixedSize()
                        // Nudged up roughly half this font's line height, so the text sits
                        // centered on its gridline rather than hanging below it.
                        .offset(y: y(atMinute: minute) - 7)
                }
            }
            .frame(width: Self.gutterWidth, height: totalHeight, alignment: .topTrailing)

            ZStack(alignment: .topLeading) {
                ForEach(hourMarks, id: \.self) { minute in
                    Rectangle()
                        .fill(Color.Offload.divider)
                        .frame(height: 1)
                        .offset(y: y(atMinute: minute))
                }
                ForEach(halfHourOnlyMarks, id: \.self) { minute in
                    Rectangle()
                        .fill(Color.Offload.divider.opacity(0.45))
                        .frame(height: 1)
                        .offset(y: y(atMinute: minute))
                }
                ForEach(entries) { entry in
                    block(for: entry)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: totalHeight)
    }

    static func label(_ start: Date, addingMinutes minutes: Int, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        let df = DateFormatter(); df.dateFormat = "h a"
        return df.string(from: date)
    }

    @ViewBuilder
    private func block(for entry: Entry) -> some View {
        let isDragging = draggingID == entry.id
        let top = isDragging ? y(for: liveSnappedStart ?? entry.start) : y(for: entry.start)
        let height = max(Self.minimumBlockHeight, y(for: entry.end) - y(for: entry.start))
        rowContent(entry)
            .frame(height: height, alignment: .top)
            .offset(y: top)
            .zIndex(isDragging ? 1 : 0)
            .opacity(isDragging ? 0.85 : 1)
            .animation(isDragging ? nil : Motion.snappy, value: top)
            .simultaneousGesture(entry.isDraggable ? dragGesture(for: entry) : nil)
    }

    /// Nearest multiple of 15, rounding (not truncating) so a small drag in either direction
    /// snaps predictably instead of always biasing toward zero.
    private func snapped(_ rawMinutes: Int, to increment: Int = 15) -> Int {
        Int((Double(rawMinutes) / Double(increment)).rounded()) * increment
    }

    private func dragGesture(for entry: Entry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 1, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                draggingID = entry.id
                let rawMinutes = Int(drag.translation.height / pointsPerMinute)
                let delta = snapped(rawMinutes)
                let candidate = calendar.date(byAdding: .minute, value: delta, to: entry.start) ?? entry.start
                liveSnappedStart = min(max(candidate, windowStart), windowEnd)
            }
            .onEnded { value in
                defer { draggingID = nil; liveSnappedStart = nil }
                guard case .second(true, let drag?) = value else { return }
                let rawMinutes = Int(drag.translation.height / pointsPerMinute)
                let delta = snapped(rawMinutes)
                let candidate = calendar.date(byAdding: .minute, value: delta, to: entry.start) ?? entry.start
                let clamped = min(max(candidate, windowStart), windowEnd)
                onReschedule(entry, DayPlanner.roundUpToQuarterHour(clamped, calendar: calendar))
            }
    }
}
