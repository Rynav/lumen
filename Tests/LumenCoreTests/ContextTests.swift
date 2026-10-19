import Foundation
import Testing
@testable import LumenCore

@Suite struct ContextWindowTests {
    @Test func knownFamiliesGetTheirWindowsAndOthersFallBack() {
        #expect(ContextWindow.tokens(for: "claude-sonnet-4-5") == 200_000)
        #expect(ContextWindow.tokens(for: "gpt-5-codex") == 272_000)
        #expect(ContextWindow.tokens(for: "gpt-4.1") == 1_047_576)
        #expect(ContextWindow.tokens(for: "gemini-2.5-pro") == 1_048_576)
        #expect(ContextWindow.tokens(for: "some-local-model") == 128_000)
    }

    @Test func estimateCountsTextToolsAndOpaqueItems() {
        let text = ContextWindow.estimate([Message(role: .user, text: String(repeating: "a", count: 4_000))])
        #expect(text >= 1_000 && text <= 1_010)
        let call = ToolCall(id: "call", name: "read_file", arguments: #"{"path":"Sources/LumenCore/Agent/ChatModel.swift"}"#)
        let tool = ContextWindow.estimate([Message(role: .assistant, parts: [.toolCall(call)])])
        #expect(tool >= 10)
        let opaque = ContextWindow.estimate([Message(role: .assistant, parts: [
            .providerItem(.object(["type": .string("reasoning"), "encrypted_content": .string(String(repeating: "b", count: 40_000))]))
        ])])
        #expect(opaque >= 10_000)
    }

    @Test func compactionCutsAtAUserMessageAndLeavesSmallChatsAlone() {
        let small = [Message(role: .user, text: "hello"), Message(role: .assistant, text: "hi")]
        #expect(ContextWindow.fits(small, model: "gpt-5"))
        #expect(ContextWindow.coverage(of: small) == nil)
        // 12 x ~10k tokens exceeds 75% of the 128k fallback window. The midpoint is
        // 6, and the newest user message before it is at index 4.
        let filler = String(repeating: "x", count: 40_000)
        let long = (0..<12).map { index in
            Message(role: index.isMultiple(of: 2) ? .user : .assistant, text: "turn \(index) \(filler)")
        }
        #expect(!ContextWindow.fits(long, model: "unknown-model"))
        #expect(ContextWindow.coverage(of: long) == 4)
        // A single huge prompt has no boundary to cut at.
        #expect(ContextWindow.coverage(of: [Message(role: .user, text: filler + filler + filler)]) == nil)
    }

    @Test @MainActor func sendingFoldsOlderTurnsIntoOneSummaryAndPersistsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })
        chat.instructionsDirectory = directory.appendingPathComponent("absent")
        let provider = MockProvider([
            [.text("Older work: inspected files and applied two edits."), .finished],
            [.text("Done."), .usage(TokenUsage(inputTokens: 100, outputTokens: 10)), .finished],
            [.text("Earlier work: files, edits, tests."), .finished],
            [.text("Finished."), .usage(TokenUsage(inputTokens: 90, outputTokens: 8)), .finished]
        ])
        chat.providerFactory = { _, _ in provider }
        let profile = ProviderProfile(name: "Mock", kind: .openAI, baseURL: "https://fixture.invalid/v1", defaultModel: "mock")
        chat.profiles = [profile]
        chat.selectedProfileID = profile.id
        chat.model = "mock"
        // 12 x ~10k tokens overflows the fallback 128k window; the cut lands before
        // the user message at index 4.
        let filler = String(repeating: "x", count: 40_000)
        chat.messages = (0..<12).map { index in
            Message(role: index.isMultiple(of: 2) ? .user : .assistant, text: "turn \(index) \(filler)")
        }
        chat.draft = "Continue"
        chat.send()
        await chat.runTask?.value

        // The first provider call is the tool-free summary, the second is the turn.
        #expect(provider.history.count == 2)
        #expect(provider.tools.first?.isEmpty == true)
        let summaryRequest = try #require(provider.history.first)
        #expect(summaryRequest.first?.text == ContextWindow.summaryInstruction)
        #expect(summaryRequest.last?.text == ContextWindow.summaryRequest)
        #expect(summaryRequest.contains { $0.text.contains("turn 3") })

        let turn = try #require(provider.history.last)
        #expect(turn.first?.role == .system)
        #expect(turn.dropFirst().first?.role == .system)
        #expect(turn[1].text.contains("Older work: inspected files"))
        #expect(!turn.contains { $0.text.contains("turn 2") })
        #expect(turn.contains { $0.text.contains("turn 4") })
        #expect(turn.last?.text == "Continue")

        // The transcript and storage keep every turn; only the request is compacted.
        #expect(chat.messages.count == 14)
        #expect(chat.isContextCompacted)
        #expect(!chat.isCompacting)
        #expect(chat.contextTokens == 110)
        let saved = try #require(ConversationStore(directory: directory).load()
            .first { $0.id == chat.currentConversationID })
        #expect(saved.compaction?.covered == 4)
        #expect(saved.compaction?.summary == "Older work: inspected files and applied two edits.")
        #expect(saved.messages.count == 14)

        // A relaunch restores the summary instead of re-summarizing the same turns.
        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.isContextCompacted)
        #expect(restored.contextMessages().dropFirst().contains { $0.text.contains("turn 4") })

        // A second compaction summarizes only the not-yet-covered tail, folds the old
        // summary in, and advances the covered count instead of redoing the prefix.
        chat.messages += (0..<8).map { index in
            Message(role: index.isMultiple(of: 2) ? .assistant : .user, text: "later \(index) \(filler)")
        }
        chat.draft = "More"
        chat.send()
        await chat.runTask?.value
        #expect(provider.history.count == 4)
        let secondSummary = try #require(provider.history.dropFirst(2).first)
        #expect(secondSummary.contains { $0.text.contains("Earlier summary:") })
        #expect(secondSummary.contains { $0.text.contains("turn 5") })
        let secondTurn = try #require(provider.history.last)
        #expect(secondTurn.contains { $0.text.contains("turn 5") } == false)
        #expect(secondTurn.contains { $0.text.contains("later 0") })
        #expect(secondTurn.last?.text == "More")
        let advanced = try #require(ConversationStore(directory: directory).load()
            .first { $0.id == chat.currentConversationID })
        #expect(advanced.compaction?.covered == 12)
    }
}
