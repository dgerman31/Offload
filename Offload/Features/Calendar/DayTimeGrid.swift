import SwiftUI

/// What `DayTimeGrid` needs from an entry to position, size, and (maybe) drag it.
protocol DayGridEntry: Identifiable {
    var start: Date { get }
    var end: Date { get }
    /// Only flexible (non-anchored) entries can be dragged — pinned times and real calendar
    /// events are commitments, not a sequence choice, same restriction the old row-to-row
    /// reorder already had.
    var isDraggable: Bool { get }
}

/// A real time-grid for one day's timed items: gridlines labeled every 30 minutes across the
/// app's day-start/end window, with each entry positioned and sized by its actual time instead
/// of stacked in a list. Flexible entries can be long-pressed and dragged to any 15-minute-
/// aligned point on the grid, including empty space — something native `.draggable`/
/// `.dropDestination` can't do (there's no discrete view to drop *onto*; the target here is an
/// arbitrary point on a continuous canvas), so this is a deliberate, scoped exception to
/// preferring native gesture primitives elsewhere in the app. The long-press gate (nothing
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

    static var hourHeight: CGFloat { 64 }
    private var pointsPerMinute: CGFloat { Self.hourHeight / 60 }
    /// A block never renders shorter than this, so even a 15-minute task stays legible — real
    /// calendars make the same trade (a very short event can visually overlap the next one
    /// rather than collapse to an unreadable sliver).
    private static var minimumBlockHeight: CGFloat { 40 }

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
    private var halfHourMarks: [Int] { Array(stride(from: 0, to: totalMinutes, by: 30)) }

    private func y(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            gutter
            ZStack(alignment: .topLeading) {
                gridLines
                ForEach(entries) { entry in
                    block(for: entry)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: totalHeight)
    }

    private var gutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(halfHourMarks, id: \.self) { minuteOffset in
                Text(Self.label(windowStart, addingMinutes: minuteOffset, calendar: calendar))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.Offload.muted)
                    .frame(height: 30 * pointsPerMinute, alignment: .top)
            }
        }
        .frame(width: 50, alignment: .trailing)
    }

    private var gridLines: some View {
        VStack(spacing: 0) {
            ForEach(halfHourMarks, id: \.self) { _ in
                Rectangle()
                    .fill(Color.Offload.divider)
                    .frame(height: 1)
                    .frame(height: 30 * pointsPerMinute, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
    }

    static func label(_ start: Date, addingMinutes minutes: Int, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        let df = DateFormatter(); df.dateFormat = "h:mm a"
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
