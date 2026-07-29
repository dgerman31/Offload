import SwiftUI

/// The grid's vertical scale, in one non-generic place so a caller building a block's *contents*
/// (`DayView`, laying a task's steps out inside its span) measures with the same ruler the grid
/// positions blocks with. Reaching for `DayTimeGrid.hourHeight` from outside would mean naming
/// its two generic parameters just to read a constant.
enum DayGridMetrics {
    /// Taller than a typical calendar app's default zoom, deliberately — more vertical room per
    /// hour so a block's own title/time text has space to breathe, at the cost of scrolling
    /// further to see the whole day.
    static let hourHeight: CGFloat = 100
    /// A block never renders shorter than this, so even a 15-minute task stays legible. It's also
    /// exactly the height of a block's title/time header, so the shortest possible block is one
    /// full header and nothing is ever squeezed.
    static let minimumBlockHeight: CGFloat = 34

    /// Dropped times land on one of these marks.
    static let snapMinutes = 15

    /// The rendered height of a block covering `minutes`.
    static func height(forMinutes minutes: Double) -> CGFloat {
        max(minimumBlockHeight, CGFloat(minutes) * hourHeight / 60)
    }

    /// How many minutes into the day's window a block dropped at `dropY` should start.
    ///
    /// Three things happen here, and each one is a bug if it's missing. The system centers a drag
    /// preview under the finger, so the release point is the block's *middle* — subtracting half
    /// its duration is what makes it land where it looks like it will, instead of half its own
    /// length late. The result snaps to a quarter-hour, so times stay readable rather than
    /// landing on 11:07. And it's clamped, so a block can't be dropped off either end of the
    /// window or hang past the end of the day.
    ///
    /// Pure and unit-tested — the alternative is verifying drag arithmetic by dragging.
    static func snappedStartMinutes(
        dropY: CGFloat,
        durationMinutes: Double,
        windowMinutes: Int,
        snap: Int = snapMinutes
    ) -> Double {
        let minutesAtFinger = Double(dropY / (hourHeight / 60))
        let rawStart = minutesAtFinger - durationMinutes / 2
        let step = Double(max(1, snap))
        let snapped = (rawStart / step).rounded() * step
        let latestStart = max(0, Double(windowMinutes) - durationMinutes)
        return min(max(0, snapped), latestStart)
    }
}

/// What `DayTimeGrid` needs from an entry to position, size, and (maybe) move it. `ID == String`
/// because a drag carries the entry's id across as its transferable payload.
protocol DayGridEntry: Identifiable where ID == String {
    var start: Date { get }
    var end: Date { get }
    /// Whether this entry's time is the app's to change. A task's is — including a pinned one,
    /// since dragging it *is* the user re-pinning it. A real calendar event's is not: it belongs
    /// to EventKit, and a gym-linked task's block mirrors a session scheduled in the Gym tab.
    var isDraggable: Bool { get }
}

/// A real time-grid for one day's timed items: gridlines every 30 minutes (only the on-the-hour
/// ones carry a printed label) across the app's day-start/end window, with each entry positioned
/// and sized by its actual time instead of stacked in a list.
///
/// **Dragging moves a block to a time.** Pick up a block, drop it anywhere on the canvas, and it
/// lands on the nearest quarter-hour to where you let go — the direct manipulation a time grid
/// implies. Nothing else on the day reflows: the one task you moved is the only one that changes.
///
/// This replaced a row-onto-row reorder (drag block A *onto* block B to re-sequence them, then
/// re-derive every time from the new order). That model failed on this screen for two compounding
/// reasons. Geometrically, blocks are the only drop targets and a day is mostly empty space at
/// 100 points per hour, so the large majority of the canvas silently rejected every drop —
/// "doesn't work at all" was an accurate description. And semantically, one drop re-planned the
/// whole day, so blocks the user hadn't touched jumped to new times. Reordering is the right verb
/// for a *list*, which is why the wake-up sheet and the "Anytime" section below still use it; it
/// was never the right verb for a grid with real coordinates.
///
/// Drag-and-drop is the system's own (`.draggable` / `.dropDestination`), not a hand-built
/// `LongPressGesture.sequenced(before: DragGesture())`. That matters here more than usual: this
/// grid lives inside a `ScrollView` inside a paging `TabView`, and a hand-built gesture has to
/// win a fight against both — the earlier one did, which is what made the screen nearly
/// unscrollable. It also has to fight `.contextMenu`, which is where Delete lives on this screen.
/// The system arbitrates all four for free: pan to scroll, swipe to page, lift-and-hold for the
/// menu, lift-and-move to drag.
struct DayTimeGrid<Entry: DayGridEntry, RowContent: View>: View {
    var entries: [Entry]
    var dayStartHour: Int
    var dayEndHour: Int
    var day: Date
    var calendar: Calendar = .current
    /// Dropped-at-a-time callback: this entry should now start here. The time is already snapped
    /// to a quarter-hour and clamped inside the day's window, so the caller just persists it.
    var onMove: (_ id: String, _ newStart: Date) -> Void
    @ViewBuilder var rowContent: (Entry) -> RowContent

    private var pointsPerMinute: CGFloat { DayGridMetrics.hourHeight / 60 }
    private static var gutterWidth: CGFloat { 54 }

    /// Width of the block column, measured once, so a drag preview is the size of the thing being
    /// dragged rather than a shrunken stand-in.
    @State private var canvasWidth: CGFloat = 0
    /// True while a drag is hovering the canvas — the quarter-hour ticks fade in, so it's visible
    /// that a drop snaps rather than landing wherever the finger happened to be.
    @State private var isDropTargeted = false

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
    /// The :15 and :45 marks, drawn only while something is being dragged.
    private var quarterMarks: [Int] {
        Array(stride(from: 0, to: totalMinutes, by: 15)).filter { $0 % 30 != 0 }
    }

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
                if isDropTargeted {
                    ForEach(quarterMarks, id: \.self) { minute in
                        Rectangle()
                            .fill(Color.Offload.indigo.opacity(0.35))
                            .frame(height: 1)
                            .offset(y: y(atMinute: minute))
                    }
                }
                ForEach(entries) { entry in
                    block(for: entry)
                }
            }
            .frame(maxWidth: .infinity, minHeight: totalHeight, alignment: .topLeading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { canvasWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in canvasWidth = new }
                }
            )
            // One drop destination covering the whole column, rather than one per block. This is
            // the change that makes dragging work: every point of the day is a valid place to let
            // go, including the empty space that is most of it.
            .dropDestination(for: String.self) { items, location in
                guard let id = items.first,
                      let entry = entries.first(where: { $0.id == id }), entry.isDraggable
                else { return false }
                onMove(id, droppedStart(at: location.y, for: entry))
                return true
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
            }
        }
        .frame(height: totalHeight)
    }

    /// Where a block dropped at `y` should start — see `DayGridMetrics.snappedStartMinutes`,
    /// which holds the arithmetic so it can be tested without a view.
    private func droppedStart(at y: CGFloat, for entry: Entry) -> Date {
        let minutes = DayGridMetrics.snappedStartMinutes(
            dropY: y,
            durationMinutes: max(1, entry.end.timeIntervalSince(entry.start) / 60),
            windowMinutes: totalMinutes
        )
        return windowStart.addingTimeInterval(minutes * 60)
    }

    static func label(_ start: Date, addingMinutes minutes: Int, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        let df = DateFormatter(); df.dateFormat = "h a"
        return df.string(from: date)
    }

    @ViewBuilder
    private func block(for entry: Entry) -> some View {
        let top = y(for: entry.start)
        let height = max(DayGridMetrics.minimumBlockHeight, y(for: entry.end) - y(for: entry.start))
        let body = rowContent(entry)
            .frame(height: height, alignment: .top)
            .offset(y: top)
            .animation(Motion.snappy, value: top)
        if entry.isDraggable {
            body.draggable(entry.id) {
                // What you see mid-drag is the block itself at its real width, capped in height
                // so a four-hour task doesn't lift a screen-tall slab under your finger.
                rowContent(entry)
                    .frame(width: canvasWidth > 0 ? canvasWidth : nil,
                           height: min(height, 64), alignment: .top)
            }
        } else {
            body
        }
    }
}
