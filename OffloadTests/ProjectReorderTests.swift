import Testing
import Foundation
@testable import Offload

/// The pure pieces behind drag-to-reorder: the SwiftUI-free `move`, and manual-order sorting.
struct ProjectReorderTests {

    private func task(_ title: String, order: Double? = nil, created: String) -> TaskItem {
        TaskItem(title: title, createdAt: created, sortOrder: order)
    }

    @Test("moved() matches SwiftUI onMove semantics (destination is a pre-removal offset)")
    func moveSemantics() {
        let items = ["A", "B", "C", "D"].map { task($0, created: $0) }
        func titles(_ ts: [TaskItem]) -> [String] { ts.map(\.title) }

        // Move the first item toward the middle.
        #expect(titles(ProjectDetailStore.moved(items, fromOffsets: [0], toOffset: 2)) == ["B", "A", "C", "D"])
        // Move a later item to the front.
        #expect(titles(ProjectDetailStore.moved(items, fromOffsets: [2], toOffset: 0)) == ["C", "A", "B", "D"])
        // Move the last item to the front.
        #expect(titles(ProjectDetailStore.moved(items, fromOffsets: [3], toOffset: 0)) == ["D", "A", "B", "C"])
    }

    @Test("Manual sort_order wins; un-dragged tasks fall back to capture order")
    func manualOrdering() {
        let dragged = [
            task("second", order: 1, created: "2026-01-01"),
            task("first", order: 0, created: "2026-01-02"),
        ]
        #expect(ProjectDetailStore.byManualOrder(dragged).map(\.title) == ["first", "second"])

        // No sort_order anywhere → capture order (created_at).
        let untouched = [
            task("newer", created: "2026-02-02"),
            task("older", created: "2026-01-01"),
        ]
        #expect(ProjectDetailStore.byManualOrder(untouched).map(\.title) == ["older", "newer"])

        // Mixed: a manually-placed task sorts ahead of never-dragged ones.
        let mixed = [
            task("undragged", created: "2026-01-01"),
            task("dragged", order: 5, created: "2026-03-03"),
        ]
        #expect(ProjectDetailStore.byManualOrder(mixed).first?.title == "dragged")
    }
}
