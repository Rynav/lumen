import Foundation
import Testing
@testable import LumenCore

@Suite struct ConfigurationTests {
    @Test @MainActor func projectsAndStandaloneChatsKeepSeparateConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })
        let generalID = chat.currentConversationID
        chat.messages = [Message(role: .user, text: "Explain\n Swift actors and isolation")]
        chat.draft = "An unfinished follow-up"
        chat.openWorkspace(directory)
        let projectID = chat.currentConversationID
        #expect(chat.workspace != nil && chat.messages.isEmpty && chat.draft.isEmpty)
        #expect(chat.conversations.first(where: { $0.id == generalID })?.title == "Explain Swift actors and isolation")
        chat.messages = [Message(role: .user, text: "Find the source")]
        chat.draft = "Project draft"
        chat.newChat()
        #expect(chat.workspace == nil && chat.messages.isEmpty && chat.draft.isEmpty)
        #expect(chat.commands.isEmpty && chat.changes.isEmpty)
        chat.selectConversation(generalID)
        #expect(chat.workspace == nil && chat.draft == "An unfinished follow-up")
        #expect(chat.messages.first?.text == "Explain\n Swift actors and isolation")
        chat.openWorkspace(directory)
        #expect(chat.currentConversationID == projectID && chat.draft == "Project draft")
        #expect(chat.messages.first?.text == "Find the source")
        #expect(chat.projectPaths == [directory.resolvingSymlinksInPath().path])
        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.projectPaths == chat.projectPaths)
        chat.newChat()
        #expect(try store.load().workspacePath == nil)
        #expect(try store.load().projectPaths == chat.projectPaths)
        chat.messages = [Message(role: .user, text: "one two three four five six seven eight nine")]
        let longTitleID = chat.currentConversationID
        chat.newChat()
        #expect(chat.conversations.first(where: { $0.id == longTitleID })?.title == "one two three four five six seven…")
    }

    @Test @MainActor func oldDefaultsUpgradeWithoutOverwritingCustomPrompts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var configuration = AppConfiguration()
        configuration.systemPrompt = "You are a helpful coding agent. Inspect the workspace before changing files."
        try store.save(configuration)
        let upgraded = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(upgraded.systemPrompt == AppConfiguration.defaultSystemPrompt)
        #expect(upgraded.maxIterations == 100)
        #expect(upgraded.systemPrompt.contains(SystemPrompt.placeholder))
        // The previous layered default is also recognized as an unedited default.
        configuration.systemPrompt = SystemPrompt.legacyDefault
        try store.save(configuration)
        #expect(ChatModel(configurationStore: store, loadAccounts: { [:] }).systemPrompt == AppConfiguration.defaultSystemPrompt)
        configuration.systemPrompt = "My own instructions"
        configuration.maxIterations = 12
        try store.save(configuration)
        let custom = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(custom.systemPrompt == "My own instructions" && custom.maxIterations == 12)
        let encoded = try JSONEncoder().encode(configuration)
        var oldJSON = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldJSON.removeValue(forKey: "projectPaths")
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(legacy.projectPaths == nil)
        configuration.workspacePath = directory.appendingPathComponent("missing-project").path
        try store.save(configuration)
        let unavailable = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(unavailable.workspace == nil && unavailable.error != nil)
        #expect(unavailable.projectPaths == [configuration.workspacePath].compactMap { $0 })
    }

    @Test @MainActor func systemMessageLayersPromptInstructionsAndAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Project house rules.".utf8).write(to: directory.appendingPathComponent("AGENTS.md"))
        try Data("attached body".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let store = ConfigurationStore(directory: directory)
        let chat = ChatModel(configurationStore: store, loadAccounts: { [:] })
        chat.openWorkspace(directory)
        chat.systemPrompt = "Custom instructions. \(SystemPrompt.placeholder)"
        chat.model = "gpt-5"
        chat.instructionsDirectory = directory.appendingPathComponent("absent")
        #expect(chat.workspace != nil)
        let system = await chat.systemMessage(attachments: ["notes.txt", "missing.txt"], tools: ["read_file", "edit_file"],
                                              agentPrompt: chat.systemPrompt, modelID: chat.model)
        // Part 0 is the custom prompt (replacing the GPT override, and filling its
        // guidance placeholder), part 1 is the baseline.
        #expect(system.hasPrefix("Custom instructions."))
        #expect(system.contains("Project house rules."))
        #expect(system.contains("Today's date:"))
        #expect(system.contains("Workspace root folder: \(directory.resolvingSymlinksInPath().path)"))
        #expect(system.contains("read_file"))
        #expect(system.contains("edit_file"))
        #expect(!system.contains(SystemPrompt.placeholder))
        #expect(!system.contains("You are Lumen"))
        // Attachments are the workspace's numbered read, bounded like any read.
        #expect(system.contains("Attached file notes.txt:\n1: attached body"))
        #expect(system.contains("Attached file missing.txt: could not be read."))
        // The default prompt keeps tool guidance and the GPT override.
        chat.systemPrompt = AppConfiguration.defaultSystemPrompt
        let defaulted = await chat.systemMessage(attachments: [], tools: ["run_command"],
                                                 agentPrompt: AppConfiguration.defaultSystemPrompt, modelID: chat.model)
        #expect(defaulted.contains("coding agent running in a native macOS app"))
        #expect(defaulted.contains("run_command"))
        #expect(!defaulted.contains(SystemPrompt.placeholder))
    }

    @Test @MainActor func settingsAndSelectedModelSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let first = ChatModel(configurationStore: store, loadAccounts: { [:] })
        let profile = ProviderProfile(name: "Saved provider", kind: .anthropic, baseURL: "https://fixture.invalid", defaultModel: "initial")
        first.profiles = [profile]
        first.selectedProfileID = profile.id
        first.model = "chosen-model"
        first.reasoning = .high
        first.systemPrompt = "Saved instructions"
        first.maxIterations = 17
        first.openWorkspace(directory)
        let restored = ChatModel(configurationStore: store, loadAccounts: { [:] })
        #expect(restored.profiles == [profile])
        #expect(restored.selectedProfileID == profile.id)
        #expect(restored.model == "chosen-model")
        #expect(restored.reasoning == .high)
        #expect(restored.systemPrompt == "Saved instructions")
        #expect(restored.maxIterations == 17)
        #expect(restored.workspace?.root == directory.resolvingSymlinksInPath())
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any])
        let profiles = try #require(json["profiles"] as? [[String: Any]])
        #expect(profiles[0]["apiKey"] == nil && profiles[0]["headers"] == nil && profiles[0]["tokens"] == nil)
    }

    @Test @MainActor func chatGPTRecoveryDoesNotOverwriteSavedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let id = UUID()
        var configuration = AppConfiguration()
        configuration.profiles = [ProviderProfile(id: id, name: "My account", kind: .chatGPT, baseURL: "https://api.openai.com/v1", defaultModel: "default")]
        configuration.selectedProfileID = id
        configuration.models[id] = "remembered"
        try store.save(configuration)
        let accounts = [id: ChatGPTAccount(clientID: "oaiapp_fixture", subject: "subject", email: "fixture@example.invalid", tokens: nil)]
        let restored = ChatModel(configurationStore: store, loadAccounts: { accounts })
        #expect(restored.profiles.count == 1)
        #expect(restored.profiles.first?.name == "My account")
        #expect(restored.model == "remembered")
    }

    @Test @MainActor func damagedConfigurationIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("damaged but must be preserved".utf8)
        let file = directory.appendingPathComponent("config.json")
        try original.write(to: file)
        let model = ChatModel(configurationStore: ConfigurationStore(directory: directory), loadAccounts: { [:] })
        #expect(model.error != nil)
        model.reasoning = .high
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func configurationDefaultsToHomeDirectoryDotLumen() throws {
        #expect(ConfigurationStore.defaultDirectory.lastPathComponent == ".lumen")
        #expect(ConfigurationStore.defaultDirectory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var configuration = AppConfiguration()
        configuration.selectedProfileID = UUID()
        configuration.models = [UUID(): "chosen-model"]
        try store.save(configuration)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
        #expect(try store.load() == configuration)
    }

    @Test func configurationDecodesFilesMissingNewerKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // An older schema: no mcpServers, no projectPaths, no selectedConversationID.
        let old = #"{"profiles":[],"selectedProfileID":"\#(UUID().uuidString)","models":{},"systemPrompt":"Keep me","maxIterations":7,"reasoning":"high"}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("config.json"))
        let configuration = try ConfigurationStore(directory: directory).load()
        #expect(configuration.systemPrompt == "Keep me")
        #expect(configuration.maxIterations == 7)
        #expect(configuration.reasoning == .high)
        #expect(configuration.mcpServers.isEmpty && configuration.projectPaths == nil)
        // A file that is not JSON at all is still reported rather than replaced with defaults.
        try Data("not json".utf8).write(to: directory.appendingPathComponent("config.json"))
        #expect(throws: (any Error).self) { try ConfigurationStore(directory: directory).load() }
    }

    @Test @MainActor func reasoningOverridesUseEachProvidersNativeField() throws {
        for effort in ReasoningEffort.allCases {
            let response = try JSONDecoder().decode(JSONValue.self, from: ChatGPTProvider.requestBody(messages: [], model: "test", tools: [], reasoning: effort))
            let compatible = try JSONDecoder().decode(JSONValue.self, from: OpenAIProvider.requestBody(messages: [], model: "test", tools: [], reasoning: effort))
            if effort == .automatic {
                #expect(response["reasoning"] == nil && compatible["reasoning_effort"] == nil)
            } else {
                #expect(response["reasoning"]?["effort"] == .string(effort.rawValue))
                #expect(compatible["reasoning_effort"] == .string(effort.rawValue))
            }
        }
    }
}
