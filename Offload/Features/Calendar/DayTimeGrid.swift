import SwiftUI

/// What `DayTimeGrid` needs from an entry to position, size, and (maybe) drag it. `ID == String`
/// because a drag carries the entry's id across as its transferable payload.
protocol DayGridEntry: Identifiable where ID == String {
    var start: Date { get }
    var end: Date { get }
    /// Whether this entry is a sequence choice rather than a commitment — only a flexible
    /// (non-anchored) task is. A real calendar event, a pinned task, and a Gym-linked task are
    /// all commitments and so aren't a drag source (or a drop target: `enabled` gates both ends
    /// of `.reorderable`).
    var isDraggable: Bool { get }
}

/// A real time-grid for one day's timed items: gridlines every 30 minutes (only the on-the-hour
/// ones carry a printed label) across the app's day-start/end window, with each entry positioned
/// and sized by its actual time instead of stacked in a list.
///
/// **Reordering is row-onto-row**, the same mechanism as the wake-up "plan my day" sheet
/// (`DayPlanView`) and the Day tab's own "Anytime" list: dragging one flexible block onto another
/// via the shared `.reorderable(id:enabled:onDrop:)` modifier re-sequences them, and the caller
/// re-derives every block's time from the new order through `DayPlanner.plan(preferredOrder:)` —
/// it does not resolve to whatever arbitrary point the block happened to be dropped at. That's
/// deliberate: a drop-anywhere-on-the-canvas model let a task land seconds away from a wildly
/// different time than intended, whereas row-onto-row only ever expresses "before/after this
/// other task," which is what a reorder actually means.
///
/// Native long-press-and-drag (`.draggable`/`.dropDestination`, wrapped by `ReorderableRow`)
/// rather than a hand-built `LongPressGesture.sequenced(before:)` — the earlier hand-built version
/// is what made this screen hard to scroll: a long-press-then-drag gesture attached to a row
/// inside a `ScrollView` competes with that scroll view for the touch, and attaching it
/// `.simultaneous`ly makes that worse rather than better. Native drag has no such problem — the
/// system owns the lift, so scrolling, tapping, and the context menu all keep working untouched.
struct DayTimeGrid<Entry: DayGridEntry, RowContent: View>: View {
    var entries: [Entry]
    var dayStartHour: Int
    var dayEndHour: Int
    var day: Date
    var calendar: Calendar = .current
    /// Dragged-onto-target callback, same shape `ReorderableRow` expects — the caller re-derives
    /// times from the new order rather than being handed a dropped time.
    var onReorder: (_ draggedID: String, _ targetID: String) -> Void
    @ViewBuilder var rowContent: (Entry) -> RowContent

    /// Taller than a typical calendar app's default zoom, deliberately — more vertical room per
    /// hour so a block's own title/time text has space to breathe, at the cost of scrolling
    /// further to see the whole day.
    static var hourHeight: CGFloat { 100 }
    private var pointsPerMinute: CGFloat { Self.hourHeight / 60 }
    /// A block never renders shorter than this, so even a 15-minute task stays legible.
    private static var minimumBlockHeight: CGFloat { 32 }
    private static var gutterWidth: CGFloat { 54 }

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
        rowContent(entry)
            .frame(height: height, alignment: .top)
            .offset(y: top)
            .animation(Motion.snappy, value: top)
            .reorderable(id: entry.id, enabled: entry.isDraggable, onDrop: onReorder)
    }
}
