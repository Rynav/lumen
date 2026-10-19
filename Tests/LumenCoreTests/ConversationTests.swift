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
        let snapshot = ConversationSnapshot(id: UUID(), projectPath: "/tmp/project",
            messages: [Message(role: .user, text: "hi")], draft: "draft", profileID: UUID(),
            usage: TokenUsage(inputTokens: 3, outputTokens: 4), estimatedCost: 0.5, savedAt: Date(timeIntervalSince1970: 10))
        try store.save([snapshot])
        #expect(store.load() == [snapshot])
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
}
