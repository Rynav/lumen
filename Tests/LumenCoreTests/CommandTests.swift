import Foundation
import Testing
@testable import LumenCore

@Suite struct CommandTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func loadsMarkdownCommandsAndSkipsUnusableFiles() throws {
        let directory = temporaryDirectory().appendingPathComponent("commands", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("# Review\nRead the change and find bugs.".utf8)
            .write(to: directory.appendingPathComponent("review.md"))
        try Data("Write a test before the fix.".utf8)
            .write(to: directory.appendingPathComponent("test.md"))
        try Data("not a command".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data("  \n".utf8).write(to: directory.appendingPathComponent("empty.md"))
        try Data("spaces are not a command name".utf8)
            .write(to: directory.appendingPathComponent("with space.md"))

        let commands = CustomCommands.load(from: directory)
        #expect(commands.map(\.name) == ["review", "test"])
        #expect(commands.first?.summary == "Review")
        #expect(commands.first?.text == "# Review\nRead the change and find bugs.")
        #expect(CustomCommands.load(from: directory.appendingPathComponent("missing")).isEmpty)
    }

    @Test @MainActor func typedSlashCommandExpandsIntoTheUserMessage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandsDirectory = directory.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        try Data("Review the current changes.".utf8)
            .write(to: commandsDirectory.appendingPathComponent("review.md"))

        let chat = ChatModel(configurationStore: ConfigurationStore(directory: directory),
                             loadAccounts: { [:] })
        chat.instructionsDirectory = directory
        chat.refreshCustomCommands()
        #expect(chat.customCommands.map(\.name) == ["review"])

        let profile = ProviderProfile(name: "Mock", kind: .openAI,
                                      baseURL: "https://fixture.invalid/v1", defaultModel: "mock")
        chat.profiles = [profile]
        chat.selectedProfileID = profile.id
        chat.model = "mock"
        let provider = MockProvider([[.text("Done."), .finished]])
        chat.providerFactory = { _, _ in provider }

        let expected = "Review the current changes.\n\nfocus on tests"
        chat.draft = "/review focus on tests"
        chat.send()
        await chat.runTask?.value

        #expect(provider.history.first?.last?.text == expected)
        #expect(chat.messages.first?.text == expected)
        #expect(chat.expandedDraft("/review") == "Review the current changes.")
        #expect(chat.expandedDraft("  /REVIEW") == "Review the current changes.")
        #expect(chat.expandedDraft("/unknown hi") == "/unknown hi")
        #expect(chat.expandedDraft("plain text") == "plain text")
    }
}
