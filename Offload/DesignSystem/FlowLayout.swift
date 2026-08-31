import SwiftUI

/// Lays subviews out left-to-right, wrapping to a new line when the next one won't fit.
///
/// An `HStack` can't do this: when it runs out of room it squeezes its children, which is why
/// cramped metadata rows were breaking words mid-syllable ("Project/s", "Hi/gh", "12/0m").
/// Here each chip keeps its natural width and moves to the next line instead.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        Self.measure(subviews.map { $0.sizeThatFits(.unspecified) },
                     maxWidth: proposal.width,
                     spacing: spacing,
                     lineSpacing: lineSpacing)
    }

    /// The geometry, over plain sizes rather than `LayoutSubviews` — which can't be constructed in
    /// a test, and this is a rule worth testing rather than trusting.
    ///
    /// `maxWidth` is the *proposal*, and `nil` is the case that matters. A nil width is not "you
    /// have infinite room": it's SwiftUI asking "how wide would you like to be?", which every
    /// `HStack` and `VStack` asks its children before dividing the real space.
    ///
    /// Answering `.infinity` meant answering with every chip laid end to end on one line. That
    /// number travelled up as the row's ideal width, past the card, to the `ScrollView` — and a
    /// `UIScrollView` scrolls on **any** axis where content exceeds bounds. So one task with a long
    /// category, a person's full name and three context tags quietly made the whole screen
    /// draggable sideways. It looked like a stray gesture; it was a layout answer.
    ///
    /// The honest ideal width is the widest single subview: the narrowest this layout can be while
    /// still laying out at all. The real pass always arrives with a concrete proposal, so this
    /// governs only the question, never the result.
    static func measure(_ sizes: [CGSize], maxWidth proposedWidth: CGFloat?,
                        spacing: CGFloat, lineSpacing: CGFloat) -> CGSize {
        let widestSubview = sizes.map(\.width).max() ?? 0
        let maxWidth = proposedWidth ?? widestSubview

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for size in sizes {
            // Wrap before placing, but never leave a line empty (x > 0 guards the first item,
            // which must be placed even if it's wider than the proposal).
            if x > 0, x + size.width > maxWidth {
                widestLine = max(widestLine, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widestLine = max(widestLine, x - spacing)

        return CGSize(
            width: maxWidth == .infinity ? max(0, widestLine) : min(maxWidth, max(0, widestLine)),
            height: y + lineHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
