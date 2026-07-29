import Testing
import Foundation
@testable import Offload

/// Steps divide their parent's block rather than getting blocks of their own — the fix for a
/// 4-hour "Enter REDCap data" appearing on the schedule beside a separate 15-minute block for
/// one of its own steps.
struct StepLayoutTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 29
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func step(_ title: String, minutes: Int? = nil) -> TaskItem {
        TaskItem(title: title, parentTaskId: "parent", effortMinutes: minutes)
    }

    @Test("Steps with no estimates split the parent's span evenly")
    func evenSplit() {
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 240,
            steps: [step("Pull export"), step("Clean column"), step("Upload")],
            calendar: calendar
        )
        // 240 minutes / 3 = 80 each: 9:00–10:20, 10:20–11:40, 11:40–1:00.
        #expect(slices.count == 3)
        #expect(slices[0].start == at(9))
        #expect(slices[0].end == at(10, 20))
        #expect(slices[1].start == at(10, 20))
        #expect(slices[1].end == at(11, 40))
        #expect(slices[2].end == at(13))   // exactly the parent's end, 9:00 + 4h
    }

    @Test("Slices tile with no gaps and no overlap")
    func tiling() {
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 100,
            steps: [step("A"), step("B"), step("C")],
            calendar: calendar
        )
        #expect(slices.count == 3)
        for (a, b) in zip(slices, slices.dropFirst()) {
            #expect(a.end == b.start)
        }
        #expect(slices.last?.end == at(10, 40))
    }

    @Test("A step's own estimate weights its share")
    func weightedByEffort() {
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 120,
            steps: [step("Short", minutes: 30), step("Long", minutes: 90)],
            calendar: calendar
        )
        #expect(slices.count == 2)
        #expect(slices[0].end == at(9, 30))
        #expect(slices[1].start == at(9, 30))
        #expect(slices[1].end == at(11))
    }

    @Test("Steps summing past the parent are scaled to fit, never overhanging it")
    func scaledDownToFit() {
        // Two hours of steps inside a one-hour parent: the parent's estimate is the truth about
        // how long the work takes, so the steps compress rather than the block stretching.
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 60,
            steps: [step("A", minutes: 60), step("B", minutes: 60)],
            calendar: calendar
        )
        #expect(slices.count == 2)
        #expect(slices[0].end == at(9, 30))
        #expect(slices.last?.end == at(10))
    }

    @Test("An unestimated step takes the average of the estimated ones")
    func averageForUnestimated() {
        // Weights 20 / 40 / 30 — the third takes the average of the two that were estimated —
        // summing to exactly the parent's 90 minutes, so each keeps its own weight.
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 90,
            steps: [step("A", minutes: 20), step("B", minutes: 40), step("C")],
            calendar: calendar
        )
        #expect(slices.count == 3)
        #expect(slices[0].end == at(9, 20))
        #expect(slices[1].end == at(10))
        #expect(slices[2].end == at(10, 30))
    }

    @Test("A span too short to show steps legibly returns none")
    func tooShortToSubdivide() {
        // 30 minutes across three steps is 10 each — a sliver. The caller falls back to a plain
        // block that says how many steps there are.
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 30,
            steps: [step("A"), step("B"), step("C")],
            calendar: calendar
        )
        #expect(slices.isEmpty)
    }

    @Test("No steps, or no duration, produces nothing")
    func degenerateInputs() {
        #expect(StepLayout.slices(parentStart: at(9), parentMinutes: 240, steps: [], calendar: calendar).isEmpty)
        #expect(StepLayout.slices(parentStart: at(9), parentMinutes: 0, steps: [step("A")], calendar: calendar).isEmpty)
    }

    @Test("Deleted steps take no share of the block")
    func deletedStepsExcluded() {
        var gone = step("Removed")
        gone.deleted = true
        let slices = StepLayout.slices(
            parentStart: at(9), parentMinutes: 120,
            steps: [step("A"), gone, step("B")],
            calendar: calendar
        )
        #expect(slices.count == 2)
        #expect(slices[0].end == at(10))
        #expect(slices[1].end == at(11))
    }
}

/// The drag-to-a-time arithmetic behind the Day tab's grid.
struct DayGridDropTests {

    /// 100 points per hour, so 60 points is 36 minutes.
    private let pointsPerMinute = DayGridMetrics.hourHeight / 60

    private func y(minutes: Double) -> CGFloat { CGFloat(minutes) * pointsPerMinute }

    @Test("A drop lands centered on the finger, not half a block late")
    func centersOnFinger() {
        // Release 120 minutes into the window holding a 60-minute block: it should start at 90,
        // so its middle sits where the finger was.
        let start = DayGridMetrics.snappedStartMinutes(
            dropY: y(minutes: 120), durationMinutes: 60, windowMinutes: 840)
        #expect(start == 90)
    }

    @Test("Start times snap to a quarter-hour")
    func snapsToQuarterHour() {
        // A 30-minute block, so the proposed start is the drop point minus 15.
        for (dropMinutes, expected) in [(37.0, 15.0), (38.0, 30.0), (52.0, 30.0), (53.0, 45.0)] {
            let start = DayGridMetrics.snappedStartMinutes(
                dropY: y(minutes: dropMinutes), durationMinutes: 30, windowMinutes: 840)
            #expect(start == expected, "dropping at \(dropMinutes) should start at \(expected)")
            #expect(start.truncatingRemainder(dividingBy: 15) == 0)
        }
    }

    @Test("A block can't be dropped before the start of the window")
    func clampsToWindowStart() {
        let start = DayGridMetrics.snappedStartMinutes(
            dropY: y(minutes: 5), durationMinutes: 120, windowMinutes: 840)
        #expect(start == 0)
    }

    @Test("A block can't be dropped hanging off the end of the day")
    func clampsToWindowEnd() {
        let start = DayGridMetrics.snappedStartMinutes(
            dropY: y(minutes: 830), durationMinutes: 120, windowMinutes: 840)
        #expect(start == 720)   // 840 - 120: the last place it fits whole
    }

    @Test("A block longer than the whole window still starts at the top")
    func longerThanWindow() {
        let start = DayGridMetrics.snappedStartMinutes(
            dropY: y(minutes: 400), durationMinutes: 900, windowMinutes: 840)
        #expect(start == 0)
    }
}
