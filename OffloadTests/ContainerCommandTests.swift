import Testing
import Foundation
@testable import Offload

/// "Talking to the app" vs "talking about my work": a command to create a container should
/// make the container, while describing something you need to do should make a task.
struct ContainerCommandTests {

    private func extracted(_ titles: [String], project: String? = nil) -> ExtractedCapture {
        ExtractedCapture(
            summary: nil,
            tasks: titles.map {
                ExtractedTask(title: $0, category: "Work", priority: "medium", contextTags: [],
                              dueDate: nil, recurrenceRule: nil, effortMinutes: nil, subtasks: [])
            },
            suggestedProject: project)
    }

    // MARK: Detection

    @Test("A leading imperative is a command; a first-person sentence is a to-do")
    func detection() {
        #expect(CaptureMapper.isContainerCommand("create a project called Jury 3"))
        #expect(CaptureMapper.isContainerCommand("make a new list for groceries"))
        #expect(CaptureMapper.isContainerCommand("please create a folder called Taxes"))
        #expect(CaptureMapper.isContainerCommand("start a project named Website"))

        // These describe the user's own work — not commands.
        #expect(!CaptureMapper.isContainerCommand("I need to create a project for the launch"))
        #expect(!CaptureMapper.isContainerCommand("I have to make a list before Friday"))
        #expect(!CaptureMapper.isContainerCommand("we should set up a project soon"))
        // Not about containers at all.
        #expect(!CaptureMapper.isContainerCommand("create the slides for Monday"))
        #expect(!CaptureMapper.isContainerCommand("buy milk"))
    }

    @Test("A container name is recovered from the words when the model misses it")
    func nameRecovery() {
        #expect(CaptureMapper.containerName(from: "create a project called Jury 3") == "Jury 3")
        #expect(CaptureMapper.containerName(from: "make a list named weekly shopping") == "Weekly shopping")
        // Stops at the clause boundary so trailing tasks aren't swept in.
        #expect(CaptureMapper.containerName(from: "create a project called Jury 3, I need to fill in the redcap") == "Jury 3")
        #expect(CaptureMapper.containerName(from: "buy milk") == nil)
    }

    // MARK: Mapping

    @Test("A bare 'create a project' command makes the project, even with no other tasks")
    func commandMakesContainer() {
        // The model set the project name and (wrongly) added a create-it task.
        let result = CaptureMapper.map(
            extracted(["Create project Jury 3"], project: "Jury 3"),
            sourceText: "create a project called Jury 3"
        )
        #expect(result.project?.title == "Jury 3")
        #expect(result.tasks.isEmpty)   // the redundant "create" task is dropped
    }

    @Test("A command still keeps the real tasks the user named alongside it")
    func commandKeepsRealTasks() {
        let result = CaptureMapper.map(
            extracted(["Create project Jury 3", "Continue filling in the REDCap", "Meeting with Andy"],
                      project: "Jury 3"),
            sourceText: "create a project called Jury 3, I need to continue filling in the redcap and meeting with Andy"
        )
        #expect(result.project?.title == "Jury 3")
        #expect(result.tasks.map(\.title) == ["Continue filling in the REDCap", "Meeting with Andy"])
        #expect(result.tasks.allSatisfy { $0.projectId == result.project?.id })
    }

    @Test("A command whose name the model dropped still recovers it from the text")
    func commandRecoversName() {
        let result = CaptureMapper.map(
            extracted([]),   // model returned nothing usable
            sourceText: "make a project called Website Redesign"
        )
        #expect(result.project?.title == "Website Redesign")
    }

    @Test("'I need to create a project' is a task, not a container")
    func firstPersonIsATask() {
        // No suggestedProject, and not a command — so it stays a plain task.
        let result = CaptureMapper.map(
            extracted(["Create a project for the launch"]),
            sourceText: "I need to create a project for the launch"
        )
        #expect(result.project == nil)
        #expect(result.tasks.map(\.title) == ["Create a project for the launch"])
    }

    @Test("Ordinary over-eager project suggestions still need two tasks to become a project")
    func nonCommandStillGated() {
        // Model suggests a project for a single errand — without a command, the gate holds.
        let result = CaptureMapper.map(
            extracted(["Buy milk"], project: "Groceries"),
            sourceText: "buy milk"
        )
        #expect(result.project == nil)
    }
}
