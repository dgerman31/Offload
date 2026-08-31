import Testing
import Foundation
@testable import Offload

/// What the model is told about this person's world before it reads their sentence.
///
/// The block worth testing hardest is the project list: without it the model invents "Thesis"
/// beside the "Thesis project" that already exists, and the two never merge.
struct CaptureContextTests {

    private func at(_ day: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: day, hour: 12))!
    }

    private func iso(_ day: Int) -> String {
        ISO8601DateFormatter().string(from: at(day))
    }

    private func task(_ title: String, kind: CaptureKind = .task, project: String? = nil,
                      created: Int = 20, done: Int? = nil) -> TaskItem {
        var item = TaskItem(title: title, projectId: project, createdAt: iso(created), kind: kind)
        if let done {
            item.status = "completed"
            item.completedAt = iso(done)
        }
        return item
    }

    // MARK: Projects

    @Test("Projects are listed with their exact titles and how live they are")
    func projectsBlockNamesThemExactly() throws {
        let project = Project(id: "p1", title: "Delirium chart review",
                              descriptionText: "Retrospective review, abstract by March")
        let world = CaptureContext.assembleWorld(
            projects: [project],
            tasks: [task("Pull the data", project: "p1"),
                    task("Could stratify by age", kind: .idea, project: "p1"),
                    task("Wrote the protocol", project: "p1", done: 19)],
            since: at(10))
        let block = try #require(CaptureContext.projectsBlock(world.projects))
        #expect(block.contains("\"Delirium chart review\""))
        #expect(block.contains("1 open"))
        #expect(block.contains("1 idea"))
        #expect(block.contains("Retrospective review"))
        // The instruction that actually prevents duplicates has to be present, not implied.
        #expect(block.lowercased().contains("near-duplicate"))
    }

    @Test("Ideas don't inflate a project's open count")
    func ideasAreNotOutstandingWork() {
        let world = CaptureContext.assembleWorld(
            projects: [Project(id: "p1", title: "Offload app")],
            tasks: (0..<8).map { task("Idea \($0)", kind: .idea, project: "p1") },
            since: at(10))
        #expect(world.projects[0].openCount == 0)
        #expect(world.projects[0].ideaCount == 8)
    }

    @Test("No projects means no block at all")
    func emptyWorldIsSilent() {
        #expect(CaptureContext.projectsBlock([]) == nil)
        #expect(CaptureContext.recentBlock([]) == nil)
        #expect(CaptureContext.openLoopsBlock(waiting: [], questions: []) == nil)
    }

    // MARK: Recent work

    @Test("Only recently touched work is included, newest first")
    func recentWorkIsWindowed() {
        let world = CaptureContext.assembleWorld(
            projects: [],
            tasks: [task("Old thing", created: 1),
                    task("Recent thing", created: 19),
                    task("Finished yesterday", created: 2, done: 19)],
            since: at(10))
        #expect(world.recentTitles.contains("Recent thing"))
        #expect(world.recentTitles.contains("Finished yesterday"))
        #expect(!world.recentTitles.contains("Old thing"))
    }

    @Test("A recurring task doesn't spend every slot saying the same thing")
    func recentWorkIsDeduplicated() {
        let world = CaptureContext.assembleWorld(
            projects: [],
            tasks: (0..<10).map { _ in task("Anki", created: 19) } + [task("Email the PI", created: 19)],
            since: at(10))
        #expect(world.recentTitles.filter { $0 == "Anki" }.count == 1)
        #expect(world.recentTitles.contains("Email the PI"))
    }

    // MARK: Open loops

    @Test("What's already outstanding is listed so an answer isn't filed as a duplicate")
    func openLoopsAreSurfaced() throws {
        let world = CaptureContext.assembleWorld(
            projects: [],
            tasks: [task("Dr. Okafor — signed form", kind: .waiting),
                    task("Do we need consent forms?", kind: .question),
                    task("Email the PI")],
            since: at(10))
        #expect(world.waiting == ["Dr. Okafor — signed form"])
        #expect(world.questions == ["Do we need consent forms?"])
        let block = try #require(CaptureContext.openLoopsBlock(waiting: world.waiting, questions: world.questions))
        #expect(block.contains("Dr. Okafor"))
        #expect(block.contains("consent forms"))
    }

    @Test("A finished waiting-on is no longer outstanding")
    func resolvedLoopsDropOut() {
        let world = CaptureContext.assembleWorld(
            projects: [],
            tasks: [task("Dr. Okafor — signed form", kind: .waiting, done: 19)],
            since: at(10))
        #expect(world.waiting.isEmpty)
    }
}
