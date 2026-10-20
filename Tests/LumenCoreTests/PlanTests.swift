import Foundation
import Testing
@testable import LumenCore

@Suite struct PlanTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("file.txt"))
        return root
    }

    @Test func planModeAdvertisesOnlyReadOnlyTools() {
        #expect(ToolRegistry.definitions(approvalIsEnabled: true, planMode: true).map(\.name)
                == ["list_files", "read_file", "search_files", "update_todos", "ask_user"])
        #expect(ToolRegistry.definitions(approvalIsEnabled: false, planMode: true).map(\.name)
                == ["list_files", "read_file", "search_files", "update_todos"])
    }

    @Test func todoToolReplacesTheChecklistAndRejectsBadInput() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ToolRegistry(workspace: try WorkspaceService(root: root))
        let call = ToolCall(id: "todos", name: "update_todos", arguments: """
            {"todos":[{"content":"Read the parser","status":"completed"},{"content":"Write the fix","status":"in_progress"}]}
            """)
        let result = try await registry.execute(call)
        #expect(!result.isError)
        #expect(result.content == "Checklist updated: 1 of 2 done.")
        for arguments in [
            #"{"todos":[{"content":"Missing status"}]}"#,
            #"{"todos":[{"content":"","status":"pending"}]}"#,
            #"{"todos":[{"content":"Bad status","status":"doing"}]}"#,
            #"{"todos":"not an array"}"#
        ] {
            let invalid = ToolCall(id: "bad", name: "update_todos", arguments: arguments)
            #expect(try await registry.execute(invalid).isError)
        }
        let cleared = try await registry.execute(ToolCall(id: "clear", name: "update_todos",
                                                          arguments: #"{"todos":[]}"#))
        #expect(!cleared.isError)
        #expect(cleared.content == "Checklist cleared.")
    }

    @Test func agentInPlanModeEmitsTodosButRefusesEditsAndExtraTools() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let todo = ToolCall(id: "todos", name: "update_todos", arguments: """
            {"todos":[{"content":"Read the file","status":"completed"},{"content":"Write the fix","status":"pending"}]}
            """)
        let edit = ToolCall(id: "edit", name: "edit_file",
                            arguments: #"{"path":"file.txt","old_text":"old","new_text":"new"}"#)
        let provider = MockProvider([[.toolCall(todo), .toolCall(edit), .finished],
                                     [.text("Plan ready."), .finished]])
        let extra = ToolDefinition(name: "mcp__server__write", description: "Write",
                                   parameters: .object(["type": .string("object")]))
        var emitted: [TodoItem] = []
        for try await event in AgentSession().run(
            messages: [Message(role: .user, text: "Plan the change")], model: "mock",
            provider: provider, workspace: try WorkspaceService(root: root), maxIterations: 3,
            approval: ApprovalGate(), planMode: true, extraTools: [extra]) {
            if case .todos(let items) = event { emitted = items }
        }
        #expect(provider.tools.first?.map(\.name)
                == ["list_files", "read_file", "search_files", "update_todos", "ask_user"])
        #expect(emitted == [TodoItem(content: "Read the file", status: .completed),
                            TodoItem(content: "Write the fix", status: .pending)])
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "old")
        let results = provider.history[1].flatMap(\.parts).compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }; return nil
        }
        let refusal = try #require(results.first { $0.callID == "edit" })
        #expect(refusal.isError)
        #expect(refusal.content.contains("Plan mode is read-only"))
    }

    @Test func planPromptStatesTheReadOnlyRule() {
        let system = SystemPrompt.system(agentPrompt: SystemPrompt.base,
                                         tools: ["read_file", "update_todos"], modelID: "mock",
                                         instructions: [], planMode: true)
        #expect(system.contains("# Plan mode"))
        #expect(system.contains("read-only first pass"))
        #expect(system.contains("update_todos"))
        let normal = SystemPrompt.system(agentPrompt: SystemPrompt.base,
                                         tools: ["read_file", "update_todos"], modelID: "mock",
                                         instructions: [])
        #expect(!normal.contains("# Plan mode"))
    }

    @Test @MainActor func checklistAndPlanModePersistAndBuildSwitchesTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = try fixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: project)
        }
        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })
        chat.instructionsDirectory = directory.appendingPathComponent("absent")
        chat.openWorkspace(project)
        let profile = ProviderProfile(name: "Mock", kind: .openAI,
                                      baseURL: "https://fixture.invalid/v1", defaultModel: "mock")
        chat.profiles = [profile]
        chat.selectedProfileID = profile.id
        chat.model = "mock"

        let todo = ToolCall(id: "todos", name: "update_todos", arguments: """
            {"todos":[{"content":"Read the file","status":"completed"},{"content":"Write the fix","status":"pending"}]}
            """)
        let provider = MockProvider([[.toolCall(todo), .finished],
                                     [.text("Plan ready."), .finished],
                                     [.text("Built."), .finished]])
        chat.providerFactory = { _, _ in provider }
        chat.setPlanMode(true)
        chat.draft = "Plan the change"
        chat.send()
        await chat.runTask?.value

        let checklist = [TodoItem(content: "Read the file", status: .completed),
                         TodoItem(content: "Write the fix", status: .pending)]
        #expect(chat.todos == checklist)
        #expect(provider.history[0].first?.text.contains("# Plan mode") == true)
        #expect(provider.tools[0].map(\.name).contains("edit_file") == false)
        #expect(ConversationStore(directory: directory).load()
            .first { $0.id == chat.currentConversationID }?.todos == checklist)

        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.currentConversationID == chat.currentConversationID)
        #expect(restored.isPlanMode)
        #expect(restored.todos == checklist)

        restored.providerFactory = { _, _ in provider }
        restored.startBuilding()
        await restored.runTask?.value
        #expect(!restored.isPlanMode)
        #expect(restored.messages.last?.text == "Built.")
        #expect(provider.history.count == 3)
        #expect(provider.history[2].first?.text.contains("# Plan mode") == false)
        #expect(provider.history[2].first?.text.contains("Current checklist") == true)
        #expect(provider.tools[2].map(\.name).contains("edit_file"))
    }
}
