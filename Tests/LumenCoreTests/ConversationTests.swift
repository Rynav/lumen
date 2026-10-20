import Foundation
import Testing
@testable import LumenCore

@Suite struct ConversationTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func storeRoundTripsSnapshots() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)
        #expect(store.load().isEmpty)
        let change = AppliedChange(proposal: FileEditProposal(id: UUID(), path: "note.txt",
            before: "old", after: "new"), backupPath: ".lumen/backups/note.json")
        let snapshot = ConversationSnapshot(id: UUID(), projectPath: "/tmp/project", title: "Named chat",
            messages: [Message(role: .user, text: "hi")], changes: [change], draft: "draft", profileID: UUID(),
            usage: TokenUsage(inputTokens: 3, outputTokens: 4), estimatedCost: 0.5, savedAt: Date(timeIntervalSince1970: 10))
        try store.save([snapshot])
        #expect(store.load() == [snapshot])
    }

    @Test func olderSnapshotsWithoutTitlesOrChangesStillLoad() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = ConversationSnapshot(id: UUID(), projectPath: nil,
            messages: [Message(role: .user, text: "hi")], draft: "", profileID: nil, usage: nil,
            estimatedCost: nil, savedAt: Date(timeIntervalSince1970: 10))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode([snapshot])) as? [[String: Any]])
        json[0].removeValue(forKey: "title")
        json[0].removeValue(forKey: "changes")
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("conversations.json"))
        let loaded = try #require(ConversationStore(directory: directory).load().first)
        #expect(loaded.title == nil)
        #expect(loaded.changes.isEmpty)
    }

    @Test func damagedHistoryFallsBackToEmpty() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("conversations.json"))
        #expect(ConversationStore(directory: directory).load().isEmpty)
    }

    @Test @MainActor func conversationsSurviveRelaunch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let first = ChatModel(configurationStore: store, loadAccounts: { [:] })
        let savedID = first.currentConversationID
        first.messages = [Message(role: .user, text: "Remember this conversation")]
        first.draft = "half-written follow-up"
        first.newChat()
        #expect(first.messages.isEmpty)

        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.conversations.contains { $0.id == savedID })
        restored.selectConversation(savedID)
        #expect(restored.messages.first?.text == "Remember this conversation")
        #expect(restored.draft == "half-written follow-up")
        #expect(restored.workspace == nil)
    }

    @Test @MainActor func chatsCanBeRenamedAndSearched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })
        chat.messages = [Message(role: .user, text: "Investigate the parser bug")]
        let id = chat.currentConversationID
        chat.renameConversation(id, to: "Parser fix")
        #expect(chat.conversations.first { $0.id == id }?.title == "Parser fix")
        chat.newChat()
        #expect(chat.searchConversations("parser").map(\.id) == [id])
        #expect(chat.searchConversations("INVESTIGATE").map(\.id) == [id])
        chat.messages = [Message(role: .user, text: "Live unsaved text")]
        #expect(chat.searchConversations("unsaved").count == 1)

        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.conversations.first { $0.id == id }?.title == "Parser fix")
        restored.renameConversation(id, to: "   ")
        #expect(restored.conversations.first { $0.id == id }?.title == "Investigate the parser bug")
    }

    @Test @MainActor func appliedChangesSurviveRelaunchAndRemainUndoable() async throws {
        let directory = temporaryDirectory()
        let project = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("file.txt")
        try Data("old\n".utf8).write(to: file)

        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })
        chat.instructionsDirectory = directory.appendingPathComponent("absent")
        chat.approvalPolicy = .autoApproveEdits
        chat.openWorkspace(project)
        let conversationID = chat.currentConversationID
        let call = ToolCall(id: "edit", name: "edit_file",
                            arguments: #"{"path":"file.txt","old_text":"old","new_text":"new"}"#)
        let provider = MockProvider([[.toolCall(call), .finished], [.text("Done."), .finished]])
        chat.providerFactory = { _, _ in provider }
        let profile = ProviderProfile(name: "Mock", kind: .openAI,
                                      baseURL: "https://fixture.invalid/v1", defaultModel: "mock")
        chat.profiles = [profile]
        chat.selectedProfileID = profile.id
        chat.model = "mock"
        chat.draft = "Edit the file"
        chat.send()
        await chat.runTask?.value
        #expect(chat.changes.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new\n")
        #expect(ConversationStore(directory: directory).load().first { $0.id == conversationID }?.changes.count == 1)

        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.changes.map(\.proposal.path) == ["file.txt"])
        let change = try #require(restored.changes.first)
        await restored.undoChange(change.id)
        #expect(restored.error == nil)
        #expect(restored.changes.first?.undone == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old\n")
        #expect(ConversationStore(directory: directory).load()
            .first { $0.id == conversationID }?.changes.first?.undone == true)
    }

    @Test @MainActor func deletingChatsAndProjectsForgetsThem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })

        let chatID = chat.currentConversationID
        chat.messages = [Message(role: .user, text: "throwaway")]
        chat.newChat()
        chat.deleteConversation(chatID)
        #expect(!chat.conversations.contains { $0.id == chatID })

        chat.openWorkspace(directory)
        let projectPath = try #require(chat.workspace?.root.path)
        let projectChatID = chat.currentConversationID
        chat.removeProject(projectPath)
        #expect(chat.projectPaths.isEmpty && chat.workspace == nil && chat.messages.isEmpty)
        #expect(!chat.conversations.contains { $0.id == projectChatID })

        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.projectPaths.isEmpty)
        #expect(!restored.conversations.contains { $0.id == chatID || $0.id == projectChatID })
    }
}
