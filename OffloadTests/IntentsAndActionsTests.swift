import Testing
import Foundation
@testable import Offload

/// Spoken answers and notification-action routing — both need to be right without a screen
/// to correct them, so both are pure and tested.
struct IntentsAndActionsTests {

    private func summary(overdue: Int = 0, dueToday: Int = 0, events: Int = 0,
                         completed: Int = 0) -> DaySummary {
        var s = DaySummary(greeting: "", headline: "", subhead: "")
        s.overdueCount = overdue
        s.dueTodayCount = dueToday
        s.eventCount = events
        s.completedToday = completed
        return s
    }

    // MARK: Spoken brief

    @Test("A clear day is said plainly rather than reciting zeroes")
    func spokenClearDay() {
        #expect(DailyBriefIntent.spokenBrief(summary()) == "Nothing needs you right now.")
        let finished = DailyBriefIntent.spokenBrief(summary(completed: 3))
        #expect(finished.contains("already finished 3"))
    }

    @Test("The brief leads with overdue and names what's next")
    func spokenBriefLeadsWithOverdue() {
        var s = summary(overdue: 2, dueToday: 1)
        s.nextTask = TaskItem(title: "Pay rent")
        let spoken = DailyBriefIntent.spokenBrief(s)
        #expect(spoken.hasPrefix("You have 2 overdue tasks"))
        #expect(spoken.contains("Pay rent"))
    }

    @Test("Singular and plural are both said correctly")
    func spokenGrammar() {
        let one = DailyBriefIntent.spokenBrief(summary(overdue: 1))
        #expect(one.contains("1 overdue task."))
        #expect(!one.contains("tasks"))

        let many = DailyBriefIntent.spokenBrief(summary(overdue: 3))
        #expect(many.contains("3 overdue tasks"))
    }

    // MARK: Spoken commitments

    @Test("Owed items are read as a natural list")
    func spokenCommitments() {
        let commitment = People.Commitment(
            name: "Sarah",
            open: [TaskItem(title: "send the deck"), TaskItem(title: "reply to her email")],
            overdueCount: 0
        )
        let spoken = CommitmentsIntent.spokenCommitments(commitment)
        #expect(spoken == "You owe Sarah: send the deck, and reply to her email.")
    }

    @Test("A long list is truncated with a count rather than read out forever")
    func spokenCommitmentsTruncate() {
        let many = (1...6).map { TaskItem(title: "thing \($0)") }
        let commitment = People.Commitment(name: "Tom", open: many, overdueCount: 0)
        let spoken = CommitmentsIntent.spokenCommitments(commitment)
        #expect(spoken.contains("Plus 3 more"))
    }

    @Test("A single item skips the list grammar")
    func spokenSingleCommitment() {
        let commitment = People.Commitment(name: "Alex", open: [TaskItem(title: "the invoice")], overdueCount: 0)
        #expect(CommitmentsIntent.spokenCommitments(commitment) == "You owe Alex: the invoice.")
    }

    // MARK: Notification routing

    @Test("Task ids are recovered from reminder identifiers")
    func notificationIdParsing() {
        #expect(NotificationDelegate.taskId(from: "task-abc-123") == "abc-123")
        #expect(NotificationDelegate.taskId(from: "daily-brief") == nil)
        #expect(NotificationDelegate.taskId(from: "task-") == nil)
        #expect(NotificationDelegate.taskId(from: "") == nil)
    }

    // MARK: Custom categories

    @Test("A new category is title-cased and accepted")
    func categoryNormalization() {
        #expect(CustomCategories.normalized("side project", existing: []) == "Side project")
        #expect(CustomCategories.normalized("  studying  ", existing: []) == "Studying")
    }

    @Test("Clashes, junk, and going over the limit are all refused")
    func categoryRejection() {
        #expect(CustomCategories.normalized("Work", existing: []) == nil)        // built-in clash
        #expect(CustomCategories.normalized("work", existing: []) == nil)        // case-insensitive
        #expect(CustomCategories.normalized("Studying", existing: ["Studying"]) == nil)
        #expect(CustomCategories.normalized("x", existing: []) == nil)           // too short
        let full = (1...CustomCategories.maxCustom).map { "Cat\($0)" }
        #expect(CustomCategories.normalized("One more", existing: full) == nil)
    }

    @Test("A user's own category survives extraction normalization")
    func customCategoryAccepted() {
        let allowed = CustomCategories.builtIn + ["Studying"]
        #expect(CaptureMapper.normalizedCategory("Studying", allowed: allowed) == "Studying")
        #expect(CaptureMapper.normalizedCategory("studying", allowed: allowed) == "Studying")
        // Anything genuinely invented still falls back.
        #expect(CaptureMapper.normalizedCategory("Wizardry", allowed: allowed) == "Other")
    }
}
