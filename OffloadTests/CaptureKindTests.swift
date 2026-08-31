import Testing
import Foundation
@testable import Offload

/// The taxonomy, and the promises it makes.
///
/// The whole point of `CaptureKind` is that an idea is not a chore, so these are mostly tests that
/// the *rules* hold rather than tests of a function: nothing timeless may be schedulable, nothing
/// that isn't an action may be reworded, and an unrecognised value from the wire can never quietly
/// become something that ends up in your calendar.
struct CaptureKindTests {

    @Test("Only actions and appointments can be scheduled")
    func onlyActionsAreSchedulable() {
        #expect(CaptureKind.task.isSchedulable)
        #expect(CaptureKind.commitment.isSchedulable)
        #expect(CaptureKind.event.isSchedulable)
        for kind: CaptureKind in [.idea, .note, .decision, .question, .waiting, .reflection] {
            #expect(!kind.isSchedulable, "\(kind.rawValue) must never be schedulable")
        }
    }

    @Test("Only actions get reworded — everything else keeps the user's words")
    func fidelityRule() {
        for kind: CaptureKind in [.task, .commitment, .event] {
            #expect(!kind.keepsWording)
        }
        for kind: CaptureKind in [.idea, .note, .decision, .question, .waiting, .reflection] {
            #expect(kind.keepsWording, "\(kind.rawValue) must keep the user's wording")
        }
    }

    @Test("Nothing schedulable is timeless, and nothing timeless is schedulable")
    func schedulableAndWordingAreOpposites() {
        // Stated as an invariant rather than a table, because the two properties encode the same
        // distinction and letting them drift apart is exactly how an idea becomes a chore again.
        for kind in CaptureKind.allCases {
            #expect(kind.isSchedulable == !kind.keepsWording)
        }
    }

    @Test("What you're still carrying is narrower than what can be ticked")
    func openLoopsAreNarrowerThanCheckable() {
        // An idea is checkable but is *not* something you're still holding — the difference these
        // two properties encode, and the reason they aren't one property.
        #expect(CaptureKind.idea.isCheckable)
        #expect(!CaptureKind.idea.countsAsOpenLoop)
        for kind: CaptureKind in [.task, .commitment, .waiting, .question] {
            #expect(kind.countsAsOpenLoop)
        }
        for kind: CaptureKind in [.idea, .note, .decision, .reflection] {
            #expect(!kind.countsAsOpenLoop)
        }
    }

    @Test("Notes and decisions have no done state")
    func checkability() {
        #expect(!CaptureKind.note.isCheckable)
        #expect(!CaptureKind.decision.isCheckable)
        #expect(CaptureKind.idea.isCheckable)
        #expect(CaptureKind.question.isCheckable)
        #expect(CaptureKind.task.isCheckable)
    }

    @Test("A reflection is never stored as a row")
    func reflectionIsNotStored() {
        #expect(!CaptureKind.reflection.isStored)
        for kind in CaptureKind.allCases where kind != .reflection {
            #expect(kind.isStored)
        }
    }

    // MARK: Parsing

    @Test("Exact wire values round-trip")
    func exactParsing() {
        for kind in CaptureKind.allCases {
            #expect(CaptureKind.parse(kind.rawValue) == kind)
        }
    }

    @Test("Near-misses the model reaches for are accepted")
    func lenientParsing() {
        #expect(CaptureKind.parse("Ideas") == .idea)
        #expect(CaptureKind.parse("TODO") == .task)
        #expect(CaptureKind.parse(" blocked ") == .waiting)
        #expect(CaptureKind.parse("appointment") == .event)
        #expect(CaptureKind.parse("venting") == .reflection)
        #expect(CaptureKind.parse("open_question") == .question)
    }

    @Test("An unknown kind falls back to a task, never to something timeless")
    func unknownFallsBackSafely() {
        // The fallback has to be the behaviour the app had before the taxonomy existed —
        // everything was a task — so an unrecognised value can't be a regression. What it must
        // never do is land on a kind that silently strips a date the user actually stated.
        #expect(CaptureKind.parse("banana") == .task)
        #expect(CaptureKind.parse(nil) == .task)
        #expect(CaptureKind.parse("") == .task)
        #expect(CaptureKind.parse("   ") == .task)
    }

    @Test("Sections are ordered actions-first, notes-last")
    func sectionOrdering() {
        #expect(CaptureKind.task.sectionRank < CaptureKind.waiting.sectionRank)
        #expect(CaptureKind.waiting.sectionRank < CaptureKind.question.sectionRank)
        #expect(CaptureKind.question.sectionRank < CaptureKind.idea.sectionRank)
        #expect(CaptureKind.idea.sectionRank < CaptureKind.note.sectionRank)
        // A task and a commitment share one heading — they're both things to do next.
        #expect(CaptureKind.task.sectionTitle == CaptureKind.commitment.sectionTitle)
    }

    // MARK: The enforcement that matters

    @Test("A task item's plannability follows its kind")
    func plannability() {
        var idea = TaskItem(title: "Could run it off the topic list", kind: .idea)
        #expect(!idea.isPlannable)
        idea.kind = CaptureKind.task.rawValue
        #expect(idea.isPlannable)

        var done = TaskItem(title: "Email the PI")
        done.status = "completed"
        #expect(!done.isPlannable)
    }

    @Test("Next-best never answers with something you can't do")
    func nextBestSkipsUnschedulable() {
        let tasks = [
            TaskItem(title: "Could try a topic-list run", priority: "high", kind: .idea),
            TaskItem(title: "Ethics number is 2026-114", priority: "high", kind: .note),
            TaskItem(title: "Email the PI", priority: "low")
        ]
        #expect(NextBest.pick(from: tasks)?.title == "Email the PI")
    }

    @Test("A pool of nothing but ideas has no next best")
    func nextBestCanBeNothing() {
        let tasks = [
            TaskItem(title: "An idea", kind: .idea),
            TaskItem(title: "Another idea", kind: .idea)
        ]
        #expect(NextBest.pick(from: tasks) == nil)
    }

    @Test("Ideas and notes are not open loops")
    func mentalLoadIgnoresTimelessThings() {
        let now = Date()
        let load = MentalLoad.compute(tasks: [
            TaskItem(title: "Email the PI"),
            TaskItem(title: "Could run it off the topic list", kind: .idea),
            TaskItem(title: "Ethics number is 2026-114", kind: .note),
            TaskItem(title: "Going with the retrospective design", kind: .decision)
        ], now: now)
        // Only the task. An idea you've written down is one you've stopped holding, which is the
        // entire promise of the app — counting it as weight would make the headline metric go *up*
        // every time offloading worked.
        #expect(load.openLoops == 1)
    }
}
