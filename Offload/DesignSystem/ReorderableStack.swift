import SwiftUI

/// Reminders-style drag reordering for a stack of rows that can't be a `List`.
///
/// ### Why this exists rather than `List` + `.onMove`
///
/// The parting-rows behaviour everyone recognises from Reminders is not a visual effect Apple
/// designed and you copy — it's what `List` does for free the moment you attach `.onMove`. The
/// framework animates the other rows aside, floats the dragged one, and drops it into the gap.
/// If these rows lived in a `List`, none of this file would exist.
///
/// They can't. The Day tab's "Anytime" group sits inside the day's `ScrollView`, below the time
/// grid, and a `List` nested in a `ScrollView` gives you two competing scroll views and a row of
/// sizing problems. So this reproduces the *behaviour* — not a dashed drop zone, not a floating
/// chip, but rows that move aside and a row that lands in the space they made.
///
/// ### What it copies, precisely
///
/// - **Press and hold to lift.** A drag can't start from a flick, so the scroll view keeps every
///   pan that belongs to it. Same `.sequenced(before:)` structure as the time grid.
/// - **The lift.** The row scales slightly and takes a shadow — it comes off the surface rather
///   than merely moving.
/// - **The parting.** Every row between where it started and where it now points slides out of the
///   way by exactly one row, animated. The gap *is* the drop indicator; there is no line, because
///   Reminders doesn't draw one.
/// - **The feel.** A medium impact on lift, a selection tick each time the insertion point moves,
///   and a spring as it lands. iOS reordering is something you feel more than watch.
///
/// Rows are assumed uniform in height, which is why the call site gives them `lineLimit(1)` —
/// Reminders truncates too, and variable heights would make "one row out of the way" a lie.
struct ReorderableStack<Item: Identifiable, Row: View>: View where Item.ID == String {
    var items: [Item]
    var spacing: CGFloat = 10
    /// Whether a given row is a sequence choice at all. A real calendar event or a pinned
    /// commitment isn't — you can't reorder something that has a time.
    var canReorder: (Item) -> Bool = { _ in true }
    /// Set while a row is in the air, so the owner can freeze its `ScrollView`.
    @Binding var isDragging: Bool
    /// The stack's ids in their new order.
    var onReorder: ([String]) -> Void
    @ViewBuilder var row: (Item) -> Row

    /// `@GestureState` so an interrupted drag resets itself — `onEnded` doesn't run on
    /// cancellation, and a stuck drag state means a stuck scroll lock. Learned the hard way on
    /// the time grid.
    @GestureState private var drag: DragState?
    @State private var rowHeight: CGFloat = 0
    @State private var landed = false
    /// The order to draw *right now*, before the store has caught up.
    ///
    /// Persisting a reorder is asynchronous — the write goes to SQLite and comes back through a
    /// `ValueObservation`. Without this, the moment you lift your finger the drag state clears and
    /// the row springs back to where it started, then jumps to its new home a frame or two later.
    /// `List` never shows you that because it reorders its own model instantly. So does this.
    @State private var pendingOrder: [String]?

    struct DragState: Equatable {
        var id: String
        var translation: CGFloat
        /// The insertion index this drag currently points at, so the haptic can fire on change.
        var target: Int
    }

    private var step: CGFloat { rowHeight + spacing }

    /// `items`, in the order the user has just put them — falling back to the real order once the
    /// store agrees, or if something else changes the contents underneath us.
    private var visible: [Item] {
        guard let pendingOrder else { return items }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = pendingOrder.compactMap { byID[$0] }
        // Anything that arrived since the drop keeps its place at the end rather than vanishing.
        let known = Set(pendingOrder)
        return reordered + items.filter { !known.contains($0.id) }
    }

    private func index(of id: String) -> Int? { visible.firstIndex { $0.id == id } }

    /// Where the dragged row would land, clamped to the stack.
    private func target(from: Int, translation: CGFloat) -> Int {
        guard step > 0 else { return from }
        let moved = Int((translation / step).rounded())
        return min(max(0, from + moved), visible.count - 1)
    }

    /// How far a row slides to make space. Exactly one row's worth, or nothing.
    private func offset(for index: Int) -> CGFloat {
        guard let drag, let from = self.index(of: drag.id) else { return 0 }
        if index == from { return drag.translation }
        let to = drag.target
        if from < to, index > from, index <= to { return -step }
        if from > to, index >= to, index < from { return step }
        return 0
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { position, item in
                let isLifted = drag?.id == item.id
                row(item)
                    .background(heightReader(enabled: position == 0))
                    .scaleEffect(isLifted ? 1.03 : 1)
                    .shadow(color: .black.opacity(isLifted ? 0.22 : 0),
                            radius: isLifted ? 14 : 0, y: isLifted ? 7 : 0)
                    .offset(y: offset(for: position))
                    .zIndex(isLifted ? 1 : 0)
                    // The lifted row tracks the finger exactly; everything else springs aside.
                    .animation(isLifted ? nil : Motion.snappy, value: drag)
                    .gesture(canReorder(item) ? gesture(for: item, at: position) : nil)
            }
        }
        .onChange(of: drag?.id) { _, id in isDragging = id != nil }
        // The store caught up, or the day's contents changed for some other reason. Either way the
        // optimistic order has done its job and the real one takes over.
        .onChange(of: items.map(\.id)) { _, _ in pendingOrder = nil }
        .onDisappear { isDragging = false }
        .sensoryFeedback(.selection, trigger: drag?.target)
        .sensoryFeedback(.impact(weight: .medium), trigger: landed)
    }

    /// One row's height is enough — they're uniform by construction.
    @ViewBuilder
    private func heightReader(enabled: Bool) -> some View {
        if enabled {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, new in rowHeight = new }
            }
        }
    }

    private func gesture(for item: Item, at position: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($drag) { value, state, transaction in
                transaction.animation = nil
                switch value {
                case .first(true):
                    state = DragState(id: item.id, translation: 0, target: position)
                case let .second(true, move):
                    let translation = move?.translation.height ?? 0
                    state = DragState(id: item.id, translation: translation,
                                      target: target(from: position, translation: translation))
                default:
                    state = nil
                }
            }
            .onChanged { value in
                if case .first(true) = value { Haptics.lift() }
            }
            .onEnded { value in
                guard case let .second(true, move) = value, let move else { return }
                let to = target(from: position, translation: move.translation.height)
                guard to != position else { return }
                var order = visible.map(\.id)
                let moving = order.remove(at: position)
                order.insert(moving, at: to)
                pendingOrder = order        // land in the gap now, not when the database says so
                landed.toggle()
                onReorder(order)
            }
    }
}
