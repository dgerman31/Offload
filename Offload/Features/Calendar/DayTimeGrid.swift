import SwiftUI

/// What `DayTimeGrid` needs from an entry to position, size, and (maybe) drag it. `ID == String`
/// because a drag carries the entry's id across as its transferable payload.
protocol DayGridEntry: Identifiable where ID == String {
    var start: Date { get }
    var end: Date { get }
    /// Any task can be dragged to any slot, including a Gym-linked or otherwise pinned one —
    /// only a real calendar event (not under this app's control to reschedule) can't be.
    var isDraggable: Bool { get }
}

/// A real time-grid for one day's timed items: gridlines every 30 minutes (only the on-the-hour
/// ones carry a printed label) across the app's day-start/end window, with each entry positioned
/// and sized by its actual time instead of stacked in a list.
///
/// **Rescheduling is native drag-and-drop** — `.draggable` on each block, one `.dropDestination`
/// covering the whole canvas — rather than a hand-built `LongPressGesture.sequenced(before:)`.
/// The earlier hand-built version is what made this screen hard to scroll: a long-press-then-drag
/// gesture attached to a row inside a `ScrollView` competes with that scroll view for the touch,
/// and attaching it `.simultaneous`ly makes that worse rather than better. Native drag has no such
/// problem — the system owns the lift, so scrolling, tapping, and the context menu all keep
/// working untouched.
///
/// Dropping anywhere on the canvas works, not just onto another block: `.dropDestination` reports
/// the drop's `location`, so an arbitrary point on a continuous surface resolves to a time through
/// the same y-to-minute math the gridlines use, snapped to the nearest 15 minutes.
struct DayTimeGrid<Entry: DayGridEntry, RowContent: View>: View {
    var entries: [Entry]
    var dayStartHour: Int
    var dayEndHour: Int
    var day: Date
    var calendar: Calendar = .current
    /// Called with the snapped `Date` a dragged entry was dropped at.
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
    /// Every dropped time lands on one of :00 / :15 / :30 / :45.
    static var snapMinutes: Int { 15 }

    @State private var isTargeted = false

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
            .frame(maxWidth: .infinity, minHeight: totalHeight, alignment: .topLeading)
            // A quiet wash while a block is held over the canvas, so it reads as a real drop
            // surface rather than the drag having nowhere to land.
            .background(isTargeted ? Color.Offload.indigo.opacity(0.06) : .clear)
            .dropDestination(for: String.self) { ids, location in
                drop(ids: ids, at: location)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
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
        let top = y(for: entry.start)
        let height = max(Self.minimumBlockHeight, y(for: entry.end) - y(for: entry.start))
        let content = rowContent(entry)
            .frame(height: height, alignment: .top)
            .offset(y: top)
            .animation(Motion.snappy, value: top)
        if entry.isDraggable {
            content.draggable(entry.id)
        } else {
            content
        }
    }

    /// Resolve a drop point on the canvas to a snapped time and hand it back. Returns whether the
    /// drop was one of ours — `false` lets the system play its "didn't take" animation rather than
    /// silently swallowing an unrelated drag.
    private func drop(ids: [String], at location: CGPoint) -> Bool {
        guard let id = ids.first, let entry = entries.first(where: { $0.id == id }) else { return false }
        let snapped = DayPlanner.nearestMultiple(Int(location.y / pointsPerMinute), of: Self.snapMinutes)
        let clamped = min(max(0, snapped), totalMinutes)
        guard let target = calendar.date(byAdding: .minute, value: clamped, to: windowStart) else { return false }
        onReschedule(entry, target)
        return true
    }
}
