import Foundation
import Testing
@testable import LumenCore

final class MockProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[StreamEvent]]
    private var requests: [[Message]] = []
    private var definitions: [[ToolDefinition]] = []
    init(_ script: [[StreamEvent]]) { self.script = script }
    var history: [[Message]] { lock.withLock { requests } }
    var tools: [[ToolDefinition]] { lock.withLock { definitions } }
    func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error> {
        let events = lock.withLock {
            requests.append(messages)
            definitions.append(tools)
            return script.isEmpty ? [StreamEvent.finished] : script.removeFirst()
        }
        return AsyncThrowingStream { output in
            for event in events { output.yield(event) }
            output.finish()
        }
    }
    func listModels() async throws -> [String] { ["mock"] }
    func cancel() async {}
}

@Suite struct AgentTests {
    @Test func reasoningUpdatesOneCollapsibleSummaryWithoutDuplicatingIt() async throws {
        let provider = MockProvider([[.reasoningSummary(id: "summary", text: "Checking "),
                                      .reasoningSummary(id: "summary", text: "Checking the source."),
                                      .reasoningSummary(id: "summary", text: "Checking the source."),
                                      .text("Answer"), .finished]])
        var latest: Message?
        for try await event in AgentSession().run(messages: [], model: "mock", provider: provider, workspace: nil, maxIterations: 1) {
            if case .message(let message) = event { latest = message }
        }
        let message = try #require(latest)
        #expect(message.parts.count == 2)
        #expect(message.reasoningSummary == "Checking the source.")
        #expect(message.text == "Answer")
    }

    @Test func editWaitsForApprovalAndContinuesWithItsResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let call = ToolCall(id: "edit", name: "edit_file", arguments: #"{"path":"file.txt","old_text":"old","new_text":"new"}"#)
        let provider = MockProvider([[.toolCall(call), .finished], [.text("Applied."), .finished]])
        let gate = ApprovalGate()
        var applied = false
        for try await event in AgentSession().run(messages: [], model: "mock", provider: provider,
            workspace: try WorkspaceService(root: root), maxIterations: 3, approval: gate) {
            switch event {
            case .approval(let proposal):
                #expect(try String(contentsOf: file, encoding: .utf8) == "old")
                #expect(provider.history.count == 1)
                await gate.decide(id: UUID(), approved: true) // Unrelated decisions cannot authorize it.
                #expect(try String(contentsOf: file, encoding: .utf8) == "old")
                await gate.decide(id: proposal.id, approved: true)
            case .applied: applied = true
            default: break
            }
        }
        #expect(applied)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(provider.history.count == 2)
    }

    @Test func rejectionAndStopLeaveFilesUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let call = ToolCall(id: "edit", name: "edit_file", arguments: #"{"path":"file.txt","old_text":"old","new_text":"new"}"#)
        let gate = ApprovalGate()
        let result = try await ToolRegistry(workspace: workspace).execute(call, approval: gate, onProposal: { proposal in
            Task { await gate.decide(id: proposal.id, approved: false) }
        })
        #expect(result.isError)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        let (started, signal) = AsyncStream<FileEditProposal>.makeStream()
        let stoppedGate = ApprovalGate()
        let task = Task {
            try await ToolRegistry(workspace: workspace).execute(call, approval: stoppedGate, onProposal: { signal.yield($0) })
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        signal.finish()
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try await ToolRegistry(workspace: workspace).execute(call).isError)
    }

    @Test func questionBlocksUntilAnsweredAndReachesTheNextTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let call = ToolCall(id: "ask", name: "ask_user",
                            arguments: #"{"question":"Which database?","options":["SQLite","Postgres"]}"#)
        let provider = MockProvider([[.toolCall(call), .finished], [.text("Using SQLite."), .finished]])
        let gate = ApprovalGate()
        var asked: UserQuestion?
        for try await event in AgentSession().run(messages: [], model: "mock", provider: provider,
                workspace: try WorkspaceService(root: root), maxIterations: 3, approval: gate) {
            if case .question(let question) = event {
                asked = question
                // The run is still blocked on this question, so no second request exists yet.
                #expect(provider.history.count == 1)
                await gate.answer(id: question.id, text: "SQLite")
            }
        }
        let question = try #require(asked)
        #expect(question.options == ["SQLite", "Postgres"])
        #expect(provider.tools.first?.map(\.name).contains("ask_user") == true)
        let results = provider.history[1].flatMap(\.parts).compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }; return nil
        }
        #expect(results.first?.content.contains("The user answered: SQLite") == true)
        #expect(results.first?.isError == false)
    }

    @Test func unansweredQuestionReturnsAnErrorInsteadOfBlocking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let call = ToolCall(id: "ask", name: "ask_user", arguments: #"{"question":"Which?","options":["a","b"]}"#)
        #expect(try await ToolRegistry(workspace: workspace).execute(call).isError)
        let gate = ApprovalGate()
        let cancelled = try await ToolRegistry(workspace: workspace).execute(call, approval: gate, onQuestion: { _ in
            Task { await gate.cancel() }
        })
        #expect(cancelled.isError)
        let tooManyOptions = ToolCall(id: "ask", name: "ask_user", arguments: #"{"question":"Which?","options":["a"]}"#)
        #expect(try await ToolRegistry(workspace: workspace).execute(tooManyOptions, approval: ApprovalGate()).isError)
    }

    @Test func toolsRunAndResultsReachNextTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture content".utf8).write(to: root.appendingPathComponent("README.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let read = ToolCall(id: "read", name: "read_file", arguments: #"{"path":"README.md"}"#)
        let denied = ToolCall(id: "denied", name: "read_file", arguments: #"{"path":"/etc/passwd"}"#)
        let provider = MockProvider([
            [.text("Inspecting."), .toolCall(read), .toolCall(denied), .usage(TokenUsage(inputTokens: 3, outputTokens: 2)), .finished],
            [.text("Found "), .text("the README."), .finished]
        ])
        var messages: [Message] = []
        for try await event in AgentSession().run(messages: [Message(role: .user, text: "Inspect")], model: "mock",
                provider: provider, workspace: try WorkspaceService(root: root), maxIterations: 3) {
            if case .message(let message) = event { messages.append(message) }
        }
        #expect(provider.history.count == 2)
        #expect(provider.tools.first?.map(\.name) == ["list_files", "read_file", "search_files"])
        let results = provider.history[1].flatMap(\.parts).compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }; return nil
        }
        #expect(results.count == 2)
        #expect(results[0].content.contains("fixture content"))
        #expect(results[1].isError)
        #expect(messages.last?.text == "Found the README.")
    }

    @Test func finalStepSummarizesWithToolsDisabled() async throws {
        let call = ToolCall(id: "call", name: "list_files", arguments: "{}")
        let provider = MockProvider([[.toolCall(call), .text("Summary of work."), .finished]])
        var messages: [Message] = []
        for try await event in AgentSession().run(messages: [Message(role: .user, text: "Explore")], model: "mock",
                provider: provider, workspace: nil, maxIterations: 1) {
            if case .message(let message) = event { messages.append(message) }
        }
        // The only request is the exhausted one: no tools, and the max-steps prompt
        // appended as an assistant message.
        #expect(provider.tools == [[]])
        #expect(provider.history.count == 1)
        #expect(provider.history[0].last?.role == .assistant)
        #expect(provider.history[0].last?.text == SystemPrompt.maxSteps)
        // A tool call that arrives anyway is refused, never executed.
        let refusal = try #require(messages.last?.parts.compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }; return nil
        }.first)
        #expect(refusal.isError)
        #expect(refusal.content == ToolResult.toolsDisabled)
        #expect(refusal.callID == "call")
    }

    @Test func chatWithoutWorkspaceAdvertisesNoTools() async throws {
        let plain = MockProvider([[.text("Hello"), .finished]])
        for try await _ in AgentSession().run(messages: [], model: "mock", provider: plain, workspace: nil, maxIterations: 2) {}
        #expect(plain.history.count == 1)
        #expect(plain.tools == [[]])
    }

    @Test func onlyTheFinalStepDropsTools() async throws {
        let search = ToolCall(id: "search", name: "search_files", arguments: #"{"query":"needle"}"#)
        let extra = ToolCall(id: "extra", name: "mcp__server__tool", arguments: "{}")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockProvider([[.toolCall(search), .finished],
                                     [.toolCall(extra), .finished],
                                     [.text("Done."), .finished]])
        for try await _ in AgentSession().run(messages: [], model: "mock", provider: provider,
            workspace: try WorkspaceService(root: root), maxIterations: 3) {}
        // Without an approval gate the tools that need a live user channel are
        // withheld from every request, and the final request advertises nothing at all.
        #expect(provider.tools.count == 3)
        #expect(provider.tools[0].map(\.name) == ["list_files", "read_file", "search_files"])
        #expect(provider.tools[1].map(\.name) == ["list_files", "read_file", "search_files"])
        #expect(provider.tools[2].isEmpty)
        // The unknown extra tool is not executed; its call still gets an error result.
        let results = provider.history[2].flatMap(\.parts).compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }; return nil
        }
        #expect(results.first { $0.callID == "extra" }?.isError == true)
    }

    @Test func interruptedToolTurnsAreRepairedOnlyOnce() {
        let first = ToolCall(id: "first", name: "read_file", arguments: "{}")
        let second = ToolCall(id: "second", name: "read_file", arguments: "{}")
        let history = [Message(role: .assistant, parts: [.toolCall(first), .toolCall(second)]),
                       Message(role: .tool, parts: [.toolResult(ToolResult(callID: "first", content: "ok"))])]
        let repaired = AgentSession.completingToolResults(in: history)
        #expect(repaired.count == 3)
        #expect(repaired[1].parts.contains { if case .toolResult(let result) = $0 { return result.callID == "second" && result.isError }; return false })
        #expect(AgentSession.completingToolResults(in: repaired) == repaired)
    }

    @Test func usageEventCarriesStreamDuration() async throws {
        let provider = MockProvider([[.text("Answer"), .usage(TokenUsage(inputTokens: 5, outputTokens: 20)), .finished]])
        var usage: TokenUsage?
        var seconds: Double?
        for try await event in AgentSession().run(messages: [], model: "mock", provider: provider, workspace: nil, maxIterations: 1) {
            if case .usage(let value, let elapsed) = event { usage = value; seconds = elapsed }
        }
        #expect(usage == TokenUsage(inputTokens: 5, outputTokens: 20))
        let elapsed = try #require(seconds)
        #expect(elapsed > 0 && elapsed.isFinite)
        #expect(TokenRate.tokensPerSecond(outputTokens: try #require(usage).outputTokens, seconds: elapsed) != nil)
    }

    @Test func cancelledRunDoesNotExecuteTools() async throws {
        let provider = MockProvider([[.toolCall(ToolCall(id: "call", name: "list_files", arguments: "{}")), .finished]])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                for try await _ in AgentSession().run(messages: [], model: "mock", provider: provider, workspace: nil, maxIterations: 2) {}
            } catch {}
        }
        await task.value
        #expect(provider.history.isEmpty)
    }

    @Test @MainActor func chatSurfacesTheQuestionAndSendsTheAnswerBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatModel(configurationStore: ConfigurationStore(directory: root.appendingPathComponent("config")),
                             loadAccounts: { [:] })
        chat.instructionsDirectory = root.appendingPathComponent("absent")
        chat.openWorkspace(root)
        let call = ToolCall(id: "ask", name: "ask_user",
                            arguments: #"{"question":"Which database?","options":["SQLite","Postgres"]}"#)
        let provider = MockProvider([[.toolCall(call), .finished], [.text("Done."), .finished]])
        chat.providerFactory = { _, _ in provider }
        let profile = ProviderProfile(name: "Mock", kind: .openAI, baseURL: "https://fixture.invalid/v1", defaultModel: "mock")
        chat.profiles = [profile]
        chat.selectedProfileID = profile.id
        chat.model = "mock"
        chat.draft = "Set up a database"
        chat.send()
        // Bounded: a broken run must fail the test instead of hanging it.
        for _ in 0..<1000 where chat.pendingQuestion == nil { await Task.yield() }
        let question = try #require(chat.pendingQuestion)
        #expect(question.options == ["SQLite", "Postgres"])
        #expect(chat.isAwaitingApproval)
        chat.answerQuestion("Postgres")
        await chat.runTask?.value
        #expect(chat.pendingQuestion == nil)
        #expect(!chat.isAwaitingApproval)
        let results = provider.history[1].flatMap(\.parts).compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }; return nil
        }
        #expect(results.first?.content.contains("The user answered: Postgres") == true)
    }
}
