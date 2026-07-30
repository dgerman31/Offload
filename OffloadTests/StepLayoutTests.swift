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
///
/// The interaction is a `DragGesture`, so what matters is the mapping from "how far the finger
/// moved" to "how many minutes that is" — snapped to a quarter-hour and clamped inside the day.
/// That mapping is pure, which is the only reason it can be checked without a device.
struct DayGridDragTests {

    /// 100 points per hour, so one minute is 1⅔ points.
    private func points(_ minutes: Double) -> CGFloat {
        CGFloat(minutes) * DayGridMetrics.pointsPerMinute
    }

    /// A 30-minute block sitting two hours into a 14-hour window — room to move either way.
    private func offset(_ dragged: Double, from: Double = 120, duration: Double = 30) -> Int {
        DayGridMetrics.snappedOffsetMinutes(
            rawOffset: points(dragged),
            minutesFromWindowStart: from,
            durationMinutes: duration,
            windowMinutes: 840
        )
    }

    @Test("Dragging down half an hour moves it half an hour — the whole point of the feature")
    func nudgeDown() {
        #expect(offset(30) == 30)
        #expect(offset(60) == 60)
    }

    @Test("Dragging up moves it earlier")
    func nudgeUp() {
        #expect(offset(-30) == -30)
        #expect(offset(-60) == -60)
    }

    @Test("Every landing is on a quarter-hour, rounding to whichever is nearer")
    func snapsToQuarterHour() {
        #expect(offset(7) == 0)     // under half a step — stays put
        #expect(offset(8) == 15)
        #expect(offset(22) == 15)
        #expect(offset(23) == 30)
        #expect(offset(37) == 30)
        #expect(offset(38) == 45)
        for dragged in stride(from: -120.0, through: 120.0, by: 3.0) {
            #expect(offset(dragged) % 15 == 0, "\(dragged) points off-grid")
        }
    }

    @Test("A tiny movement is treated as no movement, so a stray finger can't reschedule anything")
    func tinyMovementIsNoMove() {
        #expect(offset(1) == 0)
        #expect(offset(-1) == 0)
        #expect(offset(0) == 0)
    }

    @Test("A block can't be dragged above the start of the day")
    func clampsToWindowStart() {
        // It starts 120 minutes in, so it can never move more than 120 minutes earlier.
        #expect(offset(-500, from: 120) == -120)
        #expect(offset(-10_000, from: 120) == -120)
    }

    @Test("A block can't be dragged off the end of the day")
    func clampsToWindowEnd() {
        // Starting 120 in, 30 long, window 840: the latest start is 810, i.e. +690.
        #expect(offset(5_000, from: 120, duration: 30) == 690)
    }

    @Test("A block already at the very start can only move later")
    func atTheTop() {
        #expect(offset(-60, from: 0) == 0)
        #expect(offset(60, from: 0) == 60)
    }

    @Test("A block longer than the window can't be moved at all rather than moving somewhere absurd")
    func longerThanWindow() {
        #expect(offset(300, from: 0, duration: 900) == 0)
        #expect(offset(-300, from: 0, duration: 900) == 0)
    }
}
