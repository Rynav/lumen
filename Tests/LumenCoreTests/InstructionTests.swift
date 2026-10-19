import Foundation
import Testing
@testable import LumenCore

@Suite struct InstructionTests {
    private let date = Date(timeIntervalSince1970: 1_000_000_000)
    /// 1_000_000_000 seconds after the epoch is 2001-09-09 UTC.
    private let expectedDay = "September 9, 2001"

    @Test func baselineOrdersSharedSourcesBeforeVolatileOnes() throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let home = URL(fileURLWithPath: "/tmp/home/.lumen")
        let sources = Instructions.baseline(global: "Global rules.", project: "Project rules.", workspaceRoot: root,
                                            hasGitRepository: true, date: date, globalDirectory: home, platform: "darwin")
        #expect(sources.map(\.key) == ["core/instructions", "core/date", "core/environment"])
        let rendered = Instructions.render(sources)
        // Most to least shared: instruction files, then date, then environment.
        #expect(rendered.contains("Instructions from: /tmp/home/.lumen/AGENTS.md\nGlobal rules."))
        #expect(rendered.contains("Instructions from: /tmp/project/AGENTS.md\nProject rules."))
        let global = try #require(rendered.range(of: "Global rules"))
        let project = try #require(rendered.range(of: "Project rules"))
        let day = try #require(rendered.range(of: "Today's date"))
        let environment = try #require(rendered.range(of: "Workspace root folder"))
        #expect(global.lowerBound < project.lowerBound)
        #expect(project.lowerBound < day.lowerBound)
        #expect(day.lowerBound < environment.lowerBound)
    }

    @Test func environmentBlockMatchesTheOpencodeShape() throws {
        let sources = Instructions.baseline(global: nil, project: nil, workspaceRoot: URL(fileURLWithPath: "/tmp/project"),
                                            hasGitRepository: false, date: date, platform: "darwin")
        let environment = try #require(sources.first { $0.key == "core/environment" }?.text)
        #expect(environment.contains("Here is some useful information about the environment you are running in:"))
        #expect(environment.contains("<env>"))
        #expect(environment.contains("  Working directory: /tmp/project"))
        #expect(environment.contains("  Workspace root folder: /tmp/project"))
        #expect(environment.contains("  Is directory a git repo: no"))
        #expect(environment.contains("  Platform: darwin"))
        #expect(environment.hasSuffix("</env>"))
        #expect(Instructions.baseline(global: nil, project: nil, workspaceRoot: URL(fileURLWithPath: "/tmp/project"),
                                      hasGitRepository: true, date: date).first { $0.key == "core/environment" }?.text
            .contains("Is directory a git repo: yes") == true)
    }

    @Test func noProjectIsStatedInsteadOfInventingAnEnvironment() {
        let sources = Instructions.baseline(global: nil, project: nil, workspaceRoot: nil,
                                            hasGitRepository: nil, date: date)
        #expect(sources.map(\.key) == ["core/date", "core/no-project"])
        let rendered = Instructions.render(sources)
        #expect(rendered.contains("No project folder is open"))
        #expect(!rendered.contains("Workspace root folder"))
    }

    @Test func blankInstructionFilesAreSkipped() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sources = Instructions.baseline(global: "   \n", project: "", workspaceRoot: root,
                                            hasGitRepository: true, date: date)
        #expect(!sources.contains { $0.key == "core/instructions" })
        let globalOnly = Instructions.baseline(global: "Global rules.", project: nil, workspaceRoot: root,
                                               hasGitRepository: true, date: date)
        #expect(globalOnly.first?.key == "core/instructions")
        #expect(globalOnly.first?.text.contains("Global rules.") == true)
    }

    @Test func globalInstructionsAreReadFromTheAppDirectoryOnly() {
        #expect(Instructions.defaultGlobalDirectory.lastPathComponent == ".lumen")
        #expect(Instructions.defaultGlobalDirectory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test func dateIsAStableCalendarDay() {
        #expect(Instructions.dateString(date) == expectedDay)
        #expect(Instructions.dateString(date.addingTimeInterval(60)) == expectedDay)
        #expect(Instructions.baseline(global: nil, project: nil, workspaceRoot: nil, hasGitRepository: nil, date: date).first?.text
            == "Today's date: \(expectedDay)")
    }

    @Test func baselineReadsProjectAgentsFileAndGitState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# House rules\nUse tabs.".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let workspace = try WorkspaceService(root: root)
        let sources = await Instructions.load(workspace: workspace, globalDirectory: root.appendingPathComponent("absent"), date: date)
        let rendered = Instructions.render(sources)
        #expect(rendered.contains("Use tabs."))
        #expect(rendered.contains("# House rules"))
        #expect(rendered.contains("Is directory a git repo: no"))
        #expect(rendered.contains("Today's date: \(expectedDay)"))
        // Without AGENTS.md the environment block still renders; nothing is invented.
        try FileManager.default.removeItem(at: root.appendingPathComponent("AGENTS.md"))
        let bare = await Instructions.load(workspace: workspace, globalDirectory: root.appendingPathComponent("absent"), date: date)
        #expect(!Instructions.render(bare).contains("Instructions from"))
        #expect(Instructions.render(bare).contains("Workspace root folder: \(workspace.root.path)"))
    }

    @Test func readOptionalTextDoesNotThrowForMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let workspace = try WorkspaceService(root: root)
        #expect(try await workspace.readOptionalText(path: "notes.txt") == "notes")
        #expect(try await workspace.readOptionalText(path: "missing.txt") == nil)
        #expect(await workspace.hasGitDirectory() == false)
        // Paths outside the workspace are still rejected.
        await #expect(throws: WorkspaceError.self) { try await workspace.readOptionalText(path: "../outside.txt") }
    }
}
