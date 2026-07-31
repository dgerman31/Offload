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
    /// Dragged times land on one of these marks.
    static let snapMinutes = 15

    /// Scroll target for "now". Lives here rather than on `DayTimeGrid` because that type is
    /// generic, and naming both of its parameters just to read a string constant is absurd.
    static let nowAnchorID = "day-grid-now"

    static var pointsPerMinute: CGFloat { hourHeight / 60 }

    /// The rendered height of a block covering `minutes`.
    static func height(forMinutes minutes: Double) -> CGFloat {
        max(minimumBlockHeight, CGFloat(minutes) * hourHeight / 60)
    }

    /// Snap a free-dragged vertical distance to a whole number of minutes on the grid, clamped so
    /// the block stays inside the day's window.
    ///
    /// Pure, so the arithmetic that decides where a drag lands is tested rather than dragged.
    static func snappedOffsetMinutes(
        rawOffset: CGFloat,
        minutesFromWindowStart: Double,
        durationMinutes: Double,
        windowMinutes: Int,
        snap: Int = snapMinutes
    ) -> Int {
        let step = Double(max(1, snap))
        let rawMinutes = Double(rawOffset / pointsPerMinute)
        let snapped = (rawMinutes / step).rounded() * step
        // Can't go earlier than the top of the window, and can't hang off the bottom.
        let lowest = -minutesFromWindowStart
        let highest = Double(windowMinutes) - durationMinutes - minutesFromWindowStart
        return Int(min(max(snapped, lowest), max(lowest, highest)))
    }
}

/// What `DayTimeGrid` needs from an entry to position, size, and (maybe) move it.
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
/// and sized by its actual time.
///
/// **Press and hold a block, then drag it to a new time.** The block itself moves with your
/// finger at full size, a dashed line shows where it will land, the target time reads out on the
/// block, and you feel a tick each time you cross a quarter-hour. Release and it springs into
/// place. Only that task moves; nothing else on the day reflows.
///
/// ### Why this is a hand-built gesture
///
/// Two earlier versions of this screen used native drag-and-drop (`.draggable` plus
/// `.dropDestination`) and both were unusable, for reasons that are inherent to that API rather
/// than fixable within it. `.draggable` is a **data-transfer** mechanism: it hands the view to a
/// system drag session, which lifts a *snapshot* into a small floating preview. So the block
/// visibly shrank into a chip — not a style bug, that's what the API does. And a drop only counts
/// if it lands on a registered `dropDestination`, whose hit-testing is unreliable for a view
/// living inside a `ScrollView` inside a `.page`-style `TabView`, so most releases did nothing at
/// all. Direct manipulation of a coordinate — "move this down half an hour" — is simply not what
/// that API is for.
///
/// A `DragGesture` is. The scroll conflict that made an *earlier* hand-built attempt bad is solved
/// structurally here rather than fought: the drag is `.sequenced(before:)` a long press, so it
/// cannot begin until you've held still for a moment. A scroll starts with immediate movement,
/// which fails the long press, so the scroll view keeps every pan that belongs to it. Once the
/// press succeeds the touch is ours, and `isDragging` locks scrolling for the duration so nothing
/// can reclaim it mid-drag.
///
/// The cost, stated plainly: a long press can't also open a context menu, so timed blocks no
/// longer have one. Tapping still opens the task, where Delete lives — and this is what Apple's
/// own Calendar does with events for the same reason.
struct DayTimeGrid<Entry: DayGridEntry, RowContent: View>: View {
    var entries: [Entry]
    var dayStartHour: Int
    var dayEndHour: Int
    var day: Date
    var calendar: Calendar = .current
    /// Set while a block is being dragged, so the owner can freeze its `ScrollView`.
    @Binding var isDragging: Bool
    /// This entry should now start here — already snapped and clamped inside the window.
    var onMove: (_ id: String, _ newStart: Date) -> Void
    @ViewBuilder var rowContent: (Entry) -> RowContent

    private var pointsPerMinute: CGFloat { DayGridMetrics.pointsPerMinute }
    private static var gutterWidth: CGFloat { 54 }

    /// Which block is in the air, and how far the finger has moved.
    ///
    /// `@GestureState` rather than `@State`, and that's the fix for scrolling breaking after a
    /// drag: SwiftUI resets a `@GestureState` automatically when a gesture ends **or is
    /// cancelled**, whereas `@State` only gets cleared by the `onEnded` I wrote — and `onEnded`
    /// doesn't run on cancellation. One interrupted drag left `isDragging` stuck true, which meant
    /// `scrollDisabled(true)` forever and a dead screen until the app restarted.
    ///
    /// The raw offset drives the block's position so it glides 1:1 with the finger; the *snapped*
    /// value drives the guide line, the readout and the commit. Snapping the visual too would make
    /// the block jump in 25-point steps, which reads as jerky rather than precise.
    @GestureState private var activeDrag: BlockDrag?
    /// Last quarter-hour mark crossed, so the tick fires once per mark instead of once per frame.
    /// Safe as plain state: a stale value costs at most one extra haptic on the next drag.
    @State private var lastTickMinutes = 0

    /// The clock behind the now line. Read from an observable property rather than calling
    /// `Date()` inside the body, because a `Date()` read is invisible to SwiftUI — the line would
    /// be drawn once at whatever time the view happened to be built and then never move again.
    @State private var now = Date()

    struct BlockDrag: Equatable {
        var id: String
        var offset: CGFloat
    }

    private var draggingID: String? { activeDrag?.id }
    private var dragRawOffset: CGFloat { activeDrag?.offset ?? 0 }

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
    private var hourMarks: [Int] { Array(stride(from: 0, to: totalMinutes, by: 60)) }
    private var halfHourOnlyMarks: [Int] { Array(stride(from: 30, to: totalMinutes, by: 60)) }
    /// The :15 and :45 marks, drawn only while something is in the air.
    private var quarterMarks: [Int] {
        Array(stride(from: 0, to: totalMinutes, by: 15)).filter { $0 % 30 != 0 }
    }

    private func y(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }
    private func y(atMinute minute: Int) -> CGFloat { CGFloat(minute) * pointsPerMinute }

    private func minutesFromWindowStart(_ date: Date) -> Double {
        date.timeIntervalSince(windowStart) / 60
    }
    private func durationMinutes(_ entry: Entry) -> Double {
        max(1, entry.end.timeIntervalSince(entry.start) / 60)
    }

    /// Where the dragged block would land, in whole minutes relative to its own start.
    private func snappedMinutes(for entry: Entry, rawOffset: CGFloat? = nil) -> Int {
        DayGridMetrics.snappedOffsetMinutes(
            rawOffset: rawOffset ?? dragRawOffset,
            minutesFromWindowStart: minutesFromWindowStart(entry.start),
            durationMinutes: durationMinutes(entry),
            windowMinutes: totalMinutes
        )
    }

    private var draggingEntry: Entry? {
        guard let draggingID else { return nil }
        return entries.first { $0.id == draggingID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Labels and gridlines both derive their Y from the exact same `y(atMinute:)`, in
            // separate same-height columns, so a label and its line can never drift apart.
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
                gridlines
                if let entry = draggingEntry { dropGuide(for: entry) }
                ForEach(entries) { entry in
                    block(for: entry)
                }
                // Last, so it reads across the blocks it passes through rather than under them —
                // the same call Apple Calendar makes, and the reason the line is legible at all on
                // a busy morning. The block being dragged still sits above it (`zIndex` 1).
                if showsNowLine { nowLine }
            }
            .frame(maxWidth: .infinity, minHeight: totalHeight, alignment: .topLeading)
        }
        .frame(height: totalHeight)
        // A minute's resolution is all the line has; anything faster is redraws nobody can see.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
        // Driven off the gesture state rather than set imperatively inside the gesture, so a
        // cancelled drag releases the scroll lock too — `onEnded` never runs in that case.
        .onChange(of: activeDrag?.id) { _, dragging in
            isDragging = dragging != nil
        }
        .onDisappear { isDragging = false }
    }

    private var gridlines: some View {
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
            // The finer marks appear only while dragging — they'd be visual noise the rest of the
            // time, and while dragging they're the thing that explains why it snaps.
            if draggingID != nil {
                ForEach(quarterMarks, id: \.self) { minute in
                    Rectangle()
                        .fill(Color.Offload.indigo.opacity(0.25))
                        .frame(height: 1)
                        .offset(y: y(atMinute: minute))
                }
            }
        }
    }

    /// Only on today, and only while the current time is inside the day's window — a line pinned
    /// to the top edge at 3am would be a lie about where you are in the day.
    private var showsNowLine: Bool {
        calendar.isDate(day, inSameDayAs: now) && now >= windowStart && now <= windowEnd
    }

    /// Where you are in the day, as a line across it.
    @ViewBuilder
    private var nowLine: some View {
        let top = y(for: now)
        ZStack(alignment: .topLeading) {
            // The scroll target, placed with padding rather than `.offset` on purpose: `.offset`
            // moves pixels but not the layout frame, and `scrollTo` reads the frame. An offset
            // anchor silently scrolls you to the top of the day instead of to now.
            Color.clear
                .frame(width: 1, height: 1)
                .padding(.top, max(0, top))
                .id(DayGridMetrics.nowAnchorID)

            HStack(spacing: 0) {
                Circle()
                    .fill(Color.Offload.red)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(Color.Offload.red)
                    .frame(height: 1.5)
            }
            .offset(y: top - 3.5)
        }
        .allowsHitTesting(false)
    }

    /// The dashed line showing exactly where a release would put the block, with the time it
    /// would land at. This is what makes the drag feel precise rather than approximate.
    @ViewBuilder
    private func dropGuide(for entry: Entry) -> some View {
        let minutes = snappedMinutes(for: entry)
        let target = calendar.date(byAdding: .minute, value: minutes, to: entry.start) ?? entry.start
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(TimeFormat.time(target))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
                Rectangle()
                    .fill(Color.Offload.indigo)
                    .frame(height: 1.5)
            }
        }
        .offset(y: y(for: entry.start) + CGFloat(minutes) * pointsPerMinute - 9)
        .allowsHitTesting(false)
    }

    static func label(_ start: Date, addingMinutes minutes: Int, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        let df = DateFormatter(); df.dateFormat = "h a"
        return df.string(from: date)
    }

    @ViewBuilder
    private func block(for entry: Entry) -> some View {
        let isThisDragging = draggingID == entry.id
        let height = max(DayGridMetrics.minimumBlockHeight, y(for: entry.end) - y(for: entry.start))
        let top = y(for: entry.start) + (isThisDragging ? dragRawOffset : 0)

        rowContent(entry)
            .frame(height: height, alignment: .top)
            // Lifted: a touch larger, a shadow under it, and above everything else. Full size and
            // full width throughout — the thing you're moving is the block, not a stand-in for it.
            .scaleEffect(isThisDragging ? 1.03 : 1, anchor: .center)
            .shadow(color: .black.opacity(isThisDragging ? 0.28 : 0),
                    radius: isThisDragging ? 12 : 0, y: isThisDragging ? 6 : 0)
            .overlay(alignment: .topTrailing) {
                if isThisDragging { liveTimeBadge(for: entry) }
            }
            .offset(y: top)
            .zIndex(isThisDragging ? 1 : 0)
            // Not animated while this block is the one in the air: it has to track the finger
            // exactly. Everything else — including its own landing — springs.
            .animation(isThisDragging ? nil : Motion.snappy, value: top)
            .animation(Motion.snappy, value: isThisDragging)
            .gesture(entry.isDraggable ? dragGesture(for: entry) : nil)
    }

    /// The new start time, on the block, while it's moving — so you're reading the answer where
    /// you're looking rather than tracking a line across the screen.
    private func liveTimeBadge(for entry: Entry) -> some View {
        let minutes = snappedMinutes(for: entry)
        let target = calendar.date(byAdding: .minute, value: minutes, to: entry.start) ?? entry.start
        let delta = minutes == 0 ? "now" : (minutes > 0 ? "+\(minutes)m" : "\(minutes)m")
        return VStack(alignment: .trailing, spacing: 1) {
            Text(TimeFormat.time(target))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(delta)
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.Offload.indigo, in: .rect(cornerRadius: 7, style: .continuous))
        .padding(5)
        .allowsHitTesting(false)
    }

    /// Hold, then drag.
    ///
    /// `.sequenced(before:)` is doing the important work: the `DragGesture` cannot start until the
    /// `LongPressGesture` has succeeded, and a scroll — which begins moving immediately — fails
    /// that long press. So scrolling and day-paging keep working untouched, without this gesture
    /// having to compete with them for the same touch.
    private func dragGesture(for entry: Entry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            // Position lives here so it can never be left behind. `.updating` writes only to the
            // gesture state, which SwiftUI tears down for us however the gesture finishes.
            .updating($activeDrag) { value, state, transaction in
                transaction.animation = nil        // track the finger exactly, never lerp toward it
                switch value {
                case .first(true):
                    state = BlockDrag(id: entry.id, offset: 0)
                case let .second(true, drag):
                    state = BlockDrag(id: entry.id, offset: drag?.translation.height ?? 0)
                default:
                    state = nil
                }
            }
            // Feedback only — no state that matters for correctness.
            .onChanged { value in
                switch value {
                case .first(true):
                    lastTickMinutes = 0
                    Haptics.light()               // the lift
                case let .second(true, drag):
                    guard let drag else { return }
                    // One tick per quarter-hour crossed: what turns snapping from something you
                    // notice afterwards into something you feel while doing it.
                    let snapped = snappedMinutes(for: entry, rawOffset: drag.translation.height)
                    if snapped != lastTickMinutes {
                        lastTickMinutes = snapped
                        Haptics.light()
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                lastTickMinutes = 0
                guard case let .second(true, drag) = value, let drag else { return }
                let moved = snappedMinutes(for: entry, rawOffset: drag.translation.height)
                guard moved != 0,
                      let newStart = calendar.date(byAdding: .minute, value: moved, to: entry.start)
                else { return }
                onMove(entry.id, newStart)
                Haptics.success()
            }
    }
}
