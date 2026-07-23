import SwiftUI

/// Long-press-and-drag reordering for any row identified by a plain `id`, reusable wherever a
/// flat list wants native drag-to-reorder without being a real `List` — `.draggable`/
/// `.dropDestination` already know how to coexist with scrolling and tapping, unlike a
/// hand-rolled position-tracking gesture. Originally built for the Day tab's flexible-task rows;
/// the wake-up sheet's proposed-plan list reuses the exact same mechanism.
struct ReorderableRow: ViewModifier {
    let id: String
    let onDrop: (_ draggedID: String, _ targetID: String) -> Void

    @State private var width: CGFloat = 0
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in width = new }
                }
            )
            .overlay(alignment: .top) {
                if isTargeted {
                    Capsule()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .foregroundStyle(Color.Offload.indigo)
                        .frame(height: 2)
                        .offset(y: -8)
                        .transition(.opacity)
                }
            }
            .draggable(id) {
                // The same row content, pinned to its captured width — what you see mid-drag
                // is exactly what was sitting on the list, not a shrunk-down stand-in.
                content.frame(width: width > 0 ? width : nil)
            }
            .dropDestination(for: String.self, action: { items, _ in
                guard let draggedID = items.first, draggedID != id else { return false }
                onDrop(draggedID, id)
                return true
            }, isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted }
            })
    }
}

extension View {
    /// Attach reordering to a row identified by `id`. Pass `enabled: false` to make this a
    /// plain passthrough — e.g. for anchored/pinned items that aren't a sequence choice.
    @ViewBuilder
    func reorderable(id: String, enabled: Bool = true, onDrop: @escaping (_ draggedID: String, _ targetID: String) -> Void) -> some View {
        if enabled {
            self.modifier(ReorderableRow(id: id, onDrop: onDrop))
        } else {
            self
        }
    }
}
