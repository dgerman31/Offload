import Foundation

/// How a parent task's single block on the time grid divides among its steps.
///
/// A step is not a task with its own place in the day — it's part of one piece of work. Before
/// this existed, `DayPlanner.candidates` happily scheduled every step as its own block (at
/// `EnergyBatch.defaultEffort`, 15 minutes), so a 4-hour "Enter REDCap data" appeared on the
/// schedule *alongside* a 15-minute "Put REDCap data in", which is exactly what the user
/// reported. `AutoFit.needsPlanning` had always excluded steps; the two planners simply
/// disagreed. Now only the parent occupies time, and its steps tile that one span.
///
/// Pure and calendar-injected, so the division is unit-tested rather than eyeballed on device.
enum StepLayout {

    /// One step's share of its parent's block.
    struct Slice: Identifiable, Sendable, Equatable {
        let task: TaskItem
        let start: Date
        let end: Date
        var id: String { task.id }
    }

    /// Below this, a slice is a sliver too short to read — three steps inside a 30-minute block
    /// would each get a 10-point stripe. When the parent's span can't give every step at least
    /// this much, the caller gets nothing back and falls back to a plain block with a step count.
    static let minimumSliceMinutes = 12

    /// Divide `parentMinutes` starting at `parentStart` among `steps`, weighted by each step's
    /// own estimate where it has one.
    ///
    /// A step that carries an `effortMinutes` is weighted by it; one that doesn't takes the
    /// average of those that do (or an even share when none do). The result is then scaled to
    /// fill the parent's span exactly — the parent's estimate is the truth about how long the
    /// work takes, and steps that sum to more or less than it shouldn't stretch or dent the
    /// block. Slices tile with no gaps: each one starts where the last ended, because the
    /// boundaries are computed as cumulative offsets rather than by rounding each duration
    /// independently.
    ///
    /// Returns `[]` when there are no steps, when the parent has no real duration, or when the
    /// span is too short to render them legibly.
    static func slices(
        parentStart: Date,
        parentMinutes: Int,
        steps: [TaskItem],
        calendar: Calendar = .current,
        minimumSliceMinutes: Int = minimumSliceMinutes
    ) -> [Slice] {
        let visible = steps.filter { !$0.deleted }
        guard !visible.isEmpty, parentMinutes > 0 else { return [] }
        guard parentMinutes / visible.count >= minimumSliceMinutes else { return [] }

        // A step with no estimate is worth the average of the ones that have one — closer to the
        // truth than an even split when the user has sized some steps and not others.
        let stated = visible.compactMap(\.effortMinutes).filter { $0 > 0 }
        let fallback = stated.isEmpty ? 1.0 : Double(stated.reduce(0, +)) / Double(stated.count)
        let weights = visible.map { step -> Double in
            guard let minutes = step.effortMinutes, minutes > 0 else { return fallback }
            return Double(minutes)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        var slices: [Slice] = []
        var cumulativeWeight = 0.0
        var offset = 0
        for (index, weight) in weights.enumerated() {
            cumulativeWeight += weight
            // The last boundary is pinned to the parent's end rather than recomputed, so
            // accumulated rounding can never leave a one-minute gap or overhang.
            let boundary = index == weights.count - 1
                ? parentMinutes
                : Int((cumulativeWeight / total * Double(parentMinutes)).rounded())
            let end = max(offset + 1, min(boundary, parentMinutes))
            guard let sliceStart = calendar.date(byAdding: .minute, value: offset, to: parentStart),
                  let sliceEnd = calendar.date(byAdding: .minute, value: end, to: parentStart)
            else { break }
            slices.append(Slice(task: visible[index], start: sliceStart, end: sliceEnd))
            offset = end
        }
        return slices
    }
}
