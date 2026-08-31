import Testing
import CoreGraphics
@testable import Offload

/// The layout answer that made Home draggable sideways.
struct FlowLayoutTests {

    private func chips(_ widths: [CGFloat], height: CGFloat = 20) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    private func measure(_ sizes: [CGSize], width: CGFloat?) -> CGSize {
        FlowLayout.measure(sizes, maxWidth: width, spacing: 8, lineSpacing: 6)
    }

    @Test("Asked for its ideal width, it answers with one chip — never the sum of them all")
    func idealWidthIsNotTheWholeRow() {
        // This is the bug. A nil proposal is "how wide would you like to be?", asked constantly by
        // every enclosing stack. Answering with every chip end to end sent an over-wide ideal all
        // the way up to the ScrollView, which then scrolled horizontally because its content
        // genuinely was wider than its bounds.
        let size = measure(chips([80, 120, 200]), width: nil)
        #expect(size.width == 200)
        #expect(size.width < 80 + 120 + 200)
    }

    @Test("Given a real width, chips wrap and the layout never exceeds it")
    func neverExceedsTheProposal() {
        let size = measure(chips([120, 120, 120]), width: 300)
        #expect(size.width <= 300)
        // Two lines: two chips fit (120 + 8 + 120 = 248), the third wraps.
        #expect(size.height == 46)   // 20 + 6 + 20
    }

    @Test("A single chip wider than the row still can't widen the row")
    func oversizedChipIsContained() {
        // A long custom category, or a person's full name, with `.fixedSize()` on it. It may draw
        // past its lane — that's cosmetic. What it must never do is make the container wider,
        // because that is what turns into a scrollable axis.
        #expect(measure(chips([900]), width: 320).width <= 320)
        #expect(measure(chips([900, 40]), width: 320).width <= 320)
    }

    @Test("Everything on one line reports that line's width, not the proposal's")
    func shrinksToContent() {
        let size = measure(chips([60, 60]), width: 500)
        #expect(size.width == 128)   // 60 + 8 + 60
        #expect(size.height == 20)
    }

    @Test("No chips is no size")
    func emptyIsEmpty() {
        #expect(measure([], width: 300) == .zero)
        #expect(measure([], width: nil) == .zero)
    }
}
