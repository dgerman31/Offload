import SwiftUI

/// Where a project really stands, as a position on a hill.
///
/// Borrowed from Basecamp, and it earns its place here for a reason a percentage bar never could:
/// **a percentage cannot express *stuck*.** "40% done" three weeks running looks exactly like
/// "40% done" made yesterday, and for a solo project that ambiguity is the whole problem. A dot
/// that hasn't moved off the uphill is unmistakable.
///
/// The left slope is *figuring it out* — you don't yet know what the answer looks like, and any
/// estimate you make here is fiction. The right slope is *executing* — the unknowns are gone and
/// what's left is work you can honestly put in a calendar. Crossing the crest is the moment worth
/// noticing, and it's a moment a task count never shows you.
///
/// Faded dots behind the live one are previous positions, so a glance answers the real question:
/// not where is this, but **is it moving**.
struct HillChartView: View {
    /// Current position, 0…1, or nil when the project isn't tracked this way yet.
    var hill: Double?
    /// Earlier positions, oldest first. Drawn faint, and only the last few.
    var history: [Double] = []
    /// Live drag. Nil makes the chart read-only.
    var onChange: ((Double) -> Void)?
    /// Called once on release, so a drag writes one log entry rather than sixty.
    var onCommit: ((Double) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: Double?

    private var position: Double? { dragging ?? hill }
    private static let historyShown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    curve(in: size)
                        .stroke(Color.Offload.muted.opacity(0.28),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    // The crest, marked faintly. It's the only meaningful landmark on the hill —
                    // everything to its left is unknown, everything to its right is work.
                    Rectangle()
                        .fill(Color.Offload.muted.opacity(0.16))
                        .frame(width: 1)
                        .frame(height: size.height * 0.62)
                        .offset(x: size.width / 2, y: size.height * 0.38)

                    // Where it's been. Older positions are fainter, so the direction of travel
                    // reads without a legend — and four dots in the same place read as "stuck"
                    // without the word being written anywhere.
                    ForEach(Array(trailingHistory.enumerated()), id: \.offset) { index, past in
                        Circle()
                            .fill(Color.Offload.muted.opacity(0.18 + 0.06 * Double(index)))
                            .frame(width: 7, height: 7)
                            .position(point(for: past, in: size))
                    }

                    if let position {
                        Circle()
                            .fill(Color.Offload.indigo)
                            .frame(width: 15, height: 15)
                            // A ring in the page colour, so the live dot stays legible where it
                            // crosses one of its own history dots or the curve itself.
                            .overlay(Circle().strokeBorder(Color.Offload.surface, lineWidth: 2))
                            .position(point(for: position, in: size))
                            .animation(reduceMotion ? nil : Motion.snappy, value: dragging == nil)
                    }
                }
                .contentShape(Rectangle())
                // Always attached, disabled from inside. `.gesture` takes a gesture, not an
                // optional one, so the read-only case is expressed by the handler declining rather
                // than by handing SwiftUI a nil.
                .gesture(drag(in: size))
            }
            .frame(height: 96)

            Text(ProjectHill.label(position))
                .font(.Offload.taskTitle)
                .foregroundStyle(Color.Offload.text)
            if let advice = ProjectHill.advice(position) {
                Text(advice)
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hill chart")
        .accessibilityValue(ProjectHill.label(position))
        // A drag is unavailable to VoiceOver and Switch Control, so the same two moves are exposed
        // as actions — the mechanism `List` uses for its own swipe actions.
        .accessibilityAdjustableAction { direction in
            guard isEditable else { return }
            let step = 0.1
            let base = position ?? 0
            let next = ProjectHill.clamp(direction == .increment ? base + step : base - step)
            onChange?(next)
            onCommit?(next)
        }
    }

    private var trailingHistory: [Double] {
        Array(history.suffix(Self.historyShown))
    }

    private var isEditable: Bool { onChange != nil || onCommit != nil }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEditable else { return }
                let next = ProjectHill.clamp(value.location.x / max(size.width, 1))
                // One lift at the moment the dot is picked up, not one per frame.
                if dragging == nil { Haptics.lift() }
                dragging = next
                onChange?(next)
            }
            .onEnded { _ in
                guard isEditable else { return }
                // Committed once, on release, so a drag across the hill writes one log entry
                // rather than sixty.
                if let final = dragging { onCommit?(final) }
                dragging = nil
                Haptics.detent()
            }
    }

    /// A smooth bell, drawn as two mirrored cubics meeting at the crest. Deliberately a curve
    /// rather than a triangle: the shape is doing the explaining, and a hill you climb and descend
    /// is a metaphor people already have.
    private func curve(in size: CGSize) -> Path {
        var path = Path()
        let bottom = size.height - 6
        let top: CGFloat = 8
        path.move(to: CGPoint(x: 0, y: bottom))
        path.addCurve(to: CGPoint(x: size.width / 2, y: top),
                      control1: CGPoint(x: size.width * 0.22, y: bottom),
                      control2: CGPoint(x: size.width * 0.30, y: top))
        path.addCurve(to: CGPoint(x: size.width, y: bottom),
                      control1: CGPoint(x: size.width * 0.70, y: top),
                      control2: CGPoint(x: size.width * 0.78, y: bottom))
        return path
    }

    /// Where a 0…1 position sits on that curve.
    ///
    /// Solved by walking the same path rather than by inverting the cubic: the dot has to sit *on*
    /// the drawn line at every position, and an approximation that drifts a few points off the
    /// stroke is immediately visible and looks like a bug.
    private func point(for value: Double, in size: CGSize) -> CGPoint {
        let clamped = ProjectHill.clamp(value)
        let bottom = size.height - 6
        let top: CGFloat = 8
        let x = size.width * clamped
        // Both halves use the same cubic shape, so one evaluation serves both by mirroring t.
        let t = clamped <= 0.5 ? clamped * 2 : (1 - clamped) * 2
        let y = cubicY(t: t, from: bottom, to: top,
                       c1: bottom, c2: top)
        return CGPoint(x: x, y: y)
    }

    /// The y of a cubic Bézier at parameter `t`, with the control points the curve above uses.
    private func cubicY(t: Double, from p0: CGFloat, to p3: CGFloat, c1: CGFloat, c2: CGFloat) -> CGFloat {
        let mt = 1 - t
        let a = mt * mt * mt
        let b = 3 * mt * mt * t
        let c = 3 * mt * t * t
        let d = t * t * t
        return CGFloat(a) * p0 + CGFloat(b) * c1 + CGFloat(c) * c2 + CGFloat(d) * p3
    }
}
