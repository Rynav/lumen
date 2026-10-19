import Foundation
import Observation

public struct ChatConversation: Identifiable {
    public let id: UUID
    /// Recorded even before a workspace is attached, so restored chats keep their project grouping.
    public fileprivate(set) var projectPath: String?
    public var title: String {
        // ponytail: first-message titles need no extra model request; add semantic summaries if users need them.
        let words = (messages.first(where: { $0.role == .user })?.text ?? "").split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "New chat" }
        let title = words.prefix(7).joined(separator: " ")
        return String(title.prefix(48)) + (words.count > 7 || title.count > 48 ? "…" : "")
    }
    fileprivate var workspace: WorkspaceService?
    fileprivate var messages: [Message]
    fileprivate var draft: String
    fileprivate var profileID: UUID?
    fileprivate var commands: [CommandUpdate]
    fileprivate var changes: [AppliedChange]
    fileprivate var usage: TokenUsage?
    fileprivate var estimatedCost: Double?
    fileprivate var savedAt: Date

    fileprivate init(id: UUID, projectPath: String?, workspace: WorkspaceService?, messages: [Message] = [],
                     draft: String = "", profileID: UUID? = nil, commands: [CommandUpdate] = [],
                     changes: [AppliedChange] = [], usage: TokenUsage? = nil, estimatedCost: Double? = nil,
                     savedAt: Date = Date()) {
        self.id = id
        self.projectPath = projectPath ?? workspace?.root.path
        self.workspace = workspace
        self.messages = messages
        self.draft = draft
        self.profileID = profileID
        self.commands = commands
        self.changes = changes
        self.usage = usage
        self.estimatedCost = estimatedCost
        self.savedAt = savedAt
    }

    fileprivate var snapshot: ConversationSnapshot {
        ConversationSnapshot(id: id, projectPath: projectPath, messages: messages, draft: draft,
                             profileID: profileID, usage: usage, estimatedCost: estimatedCost, savedAt: savedAt)
    }
}

@MainActor @Observable
public final class ChatModel {
    public var profiles: [ProviderProfile] = [] { didSet { persistConfiguration() } }
    public var selectedProfileID: UUID? { didSet { if !restoringConfiguration { selectProfile() } } }
    public var model = "" { didSet {
        if !restoringConfiguration, let id = selectedProfileID { configuration.models[id] = model }
        persistConfiguration()
    } }
    public var systemPrompt = AppConfiguration().systemPrompt { didSet { persistConfiguration() } }
    public var maxIterations = AppConfiguration().maxIterations { didSet { persistConfiguration() } }
    public var reasoning = ReasoningEffort.automatic { didSet { persistConfiguration() } }
    public var approvalPolicy = ApprovalPolicy.reviewEverything { didSet { persistConfiguration() } }
    public var mcpServers: [MCPServerConfig] = [] { didSet { persistConfiguration() } }
    public var messages: [Message] = []
    public private(set) var modelInfo: [ModelInfo] = []
    public var draft = ""
    /// Project-relative files folded into the next turn's context, then cleared.
    public private(set) var attachments: [String] = []
    /// Images pasted into the composer, sent inline with the next turn, then cleared.
    public private(set) var attachedImages: [ImageAttachment] = []
    public var error: String?
    public var usage: TokenUsage?
    /// Output tokens per second across the last turn's provider streams; nil until one reports usage.
    public private(set) var tokensPerSecond: Double?
    public var estimatedCost: Double?
    public private(set) var workspace: WorkspaceService?
    public private(set) var projectPaths: [String] = []
    public private(set) var conversations: [ChatConversation] = []
    public private(set) var currentConversationID = UUID()
    public private(set) var isRunning = false
    public private(set) var isLoadingModels = false
    public var pendingEdit: FileEditProposal?
    public var pendingCommand: CommandProposal?
    public private(set) var commands: [CommandUpdate] = []
    public var isAwaitingApproval: Bool { pendingEdit != nil || pendingCommand != nil }
    public private(set) var changes: [AppliedChange] = []
    public private(set) var isGitRepository = false
    public private(set) var gitStatus: [GitFileStatus] = []
    public private(set) var gitDiff = ""
    public private(set) var workspaceRevision = 0
    public private(set) var isUndoing = false
    public var isBusy: Bool { isRunning || isUndoing }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var provider: (any LLMProvider)?
    @ObservationIgnored private var conversationProfileID: UUID?
    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let conversationStore: ConversationStore
    @ObservationIgnored private var configuration = AppConfiguration()
    @ObservationIgnored private var restoringConfiguration = true
    @ObservationIgnored private var configurationWritable = false
    @ObservationIgnored private var approvalGate: ApprovalGate?
    /// Where the global `AGENTS.md` is read from. Injectable so tests never depend
    /// on the machine's real home directory.
    @ObservationIgnored var instructionsDirectory = Instructions.defaultGlobalDirectory
    @ObservationIgnored private var mcpClients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var mcpToolMap: [String: (client: MCPClient, tool: String)] = [:]

    public init(configurationStore: ConfigurationStore = ConfigurationStore(),
                loadAccounts: @Sendable () throws -> [UUID: ChatGPTAccount] = { try KeychainStore().loadChatGPTAccounts() },
                conversationStore: ConversationStore? = nil) {
        self.configurationStore = configurationStore
        self.conversationStore = conversationStore ?? ConversationStore(directory: configurationStore.directory)
        do {
            configuration = try configurationStore.load()
            configurationWritable = true
            profiles = configuration.profiles
            systemPrompt = configuration.systemPrompt
            // A prompt still equal to a shipped default was never customized, so it
            // moves to the current default. Anything the user wrote is preserved.
            if AppConfiguration.legacySystemPrompts.contains(systemPrompt) {
                systemPrompt = AppConfiguration.defaultSystemPrompt
            }
            maxIterations = max(1, min(configuration.maxIterations, 1_000))
            reasoning = configuration.reasoning
            approvalPolicy = configuration.approvalPolicy
            mcpServers = configuration.mcpServers
            projectPaths = configuration.projectPaths ?? []
            if let path = configuration.workspacePath, !projectPaths.contains(path) { projectPaths.insert(path, at: 0) }
            if let path = configuration.workspacePath { workspace = try WorkspaceService(root: URL(fileURLWithPath: path)) }
        } catch { self.error = "Could not restore configuration: \(error.localizedDescription)" }
        do {
            for (id, account) in try loadAccounts().sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !profiles.contains(where: { $0.id == id }) {
                profiles.append(ProviderProfile(id: id, name: "ChatGPT · \(account.email ?? "Account") · \(account.clientID.suffix(6))",
                    kind: .chatGPT, baseURL: "https://api.openai.com/v1", defaultModel: ""))
            }
        } catch { self.error = error.localizedDescription }
        selectedProfileID = profiles.first(where: { $0.id == configuration.selectedProfileID })?.id ?? profiles.first?.id
        model = selectedProfileID.flatMap { configuration.models[$0] } ?? selectedProfile?.defaultModel ?? ""
        if let path = workspace?.root.path, !projectPaths.contains(path) { projectPaths.insert(path, at: 0) }
        restoreConversations()
        restoringConfiguration = false
        persistConfiguration()
    }

    /// Restores saved chats, reattaching the current workspace and the last active conversation.
    private func restoreConversations() {
        let snapshots = conversationStore.load().sorted { $0.savedAt > $1.savedAt }
        conversations = snapshots.map { snapshot in
            var conversation = ChatConversation(id: snapshot.id, projectPath: snapshot.projectPath, workspace: nil,
                messages: snapshot.messages, draft: snapshot.draft, profileID: snapshot.profileID,
                usage: snapshot.usage, estimatedCost: snapshot.estimatedCost, savedAt: snapshot.savedAt)
            if snapshot.projectPath == workspace?.root.path { conversation.workspace = workspace }
            return conversation
        }
        if let id = configuration.selectedConversationID, let conversation = conversations.first(where: { $0.id == id }) {
            load(conversation)
        } else if let conversation = conversations.first {
            load(conversation)
        } else {
            saveConversation()
            return
        }
        saveConversation()
    }

    private func persistConfiguration() {
        guard !restoringConfiguration, configurationWritable else { return }
        configuration.profiles = profiles
        configuration.selectedProfileID = selectedProfileID
        configuration.systemPrompt = systemPrompt
        configuration.maxIterations = maxIterations
        configuration.reasoning = reasoning
        configuration.approvalPolicy = approvalPolicy
        configuration.mcpServers = mcpServers
        configuration.projectPaths = projectPaths
        configuration.workspacePath = workspace?.root.path
        configuration.selectedConversationID = currentConversationID
        do { try configurationStore.save(configuration) }
        catch { self.error = "Could not save configuration: \(error.localizedDescription)" }
    }

    public func openWorkspace(_ url: URL) {
        guard !isBusy else { return }
        do {
            let opened = try WorkspaceService(root: url)
            if let existing = conversations.first(where: { $0.projectPath == opened.root.path }) {
                if let index = conversations.firstIndex(where: { $0.id == existing.id }) { conversations[index].workspace = opened }
                if existing.id == currentConversationID { workspace = opened } else { selectConversation(existing.id) }
            } else {
                startConversation(workspace: opened)
            }
            projectPaths.removeAll { $0 == opened.root.path }
            projectPaths.insert(opened.root.path, at: 0)
            persistConfiguration()
        } catch { self.error = error.localizedDescription }
    }

    public var selectedProfile: ProviderProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    public func selectProfile() {
        model = selectedProfileID.flatMap { configuration.models[$0] } ?? selectedProfile?.defaultModel ?? ""
        modelInfo = []
        persistConfiguration()
        Task { await loadModels() }
    }

    public func loadModels() async {
        guard let profile = selectedProfile else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let available = try await Self.makeProvider(profile).modelInfo()
            guard selectedProfileID == profile.id else { return }
            modelInfo = profile.kind == .chatGPT ? available : available.sorted { $0.label < $1.label }
            if model.isEmpty { model = modelInfo.first?.id ?? "" }
        } catch { if selectedProfileID == profile.id { self.error = error.localizedDescription } }
    }

    public func attach(_ path: String) {
        if !attachments.contains(path) { attachments.append(path) }
    }

    public func detach(_ path: String) {
        attachments.removeAll { $0 == path }
    }

    public func attachImage(_ image: ImageAttachment) {
        attachedImages.append(image)
    }

    public func detachImage(_ image: ImageAttachment) {
        attachedImages.removeAll { $0 == image }
    }

    /// Builds the one system message a turn starts with: the agent prompt or base
    /// prompt, the instruction baseline, and the attached files folded in as extra
    /// context. The prompt and model are passed in so a settings change mid-flight
    /// cannot alter a turn that already started.
    func systemMessage(attachments: [String], tools: [String], agentPrompt: String, modelID: String) async -> String {
        var context = ""
        if let workspace {
            for path in attachments {
                if let contents = try? await workspace.readFile(path: path, limit: 500) {
                    context += "\n\nAttached file \(path):\n\(contents)"
                } else {
                    context += "\n\nAttached file \(path): could not be read."
                }
            }
        }
        let instructions = await Instructions.load(workspace: workspace, globalDirectory: instructionsDirectory)
        return SystemPrompt.system(agentPrompt: agentPrompt, tools: tools, modelID: modelID,
                                   instructions: instructions) + context
    }

    /// Connects enabled MCP servers and maps their tools to namespaced definitions.
    private func ensureMCPTools() async -> [ToolDefinition] {
        mcpToolMap = [:]
        var definitions: [ToolDefinition] = []
        let configs = mcpServers.filter { $0.enabled && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        for (id, client) in mcpClients where !configs.contains(where: { $0.id == id }) {
            await client.disconnect(); mcpClients[id] = nil
        }
        for config in configs {
            let client = mcpClients[config.id] ?? MCPClient(config: config)
            mcpClients[config.id] = client
            do {
                try await client.connect()
                for tool in try await client.listTools() {
                    let name = Self.namespaced("mcp__\(config.name)__\(tool.name)")
                    definitions.append(ToolDefinition(name: name,
                        description: tool.description.isEmpty ? "MCP tool \(tool.name)" : tool.description,
                        parameters: tool.inputSchema))
                    mcpToolMap[name] = (client, tool.name)
                }
            } catch { self.error = "MCP server “\(config.name)”: \(error.localizedDescription)" }
        }
        return definitions
    }

    private static func namespaced(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    public func refreshGitReview() async {
        guard let root = workspace?.root else {
            isGitRepository = false; gitStatus = []; gitDiff = ""; return
        }
        let git = GitService(root: root)
        isGitRepository = await git.isRepository()
        guard isGitRepository else { gitStatus = []; gitDiff = ""; return }
        do {
            gitStatus = try await git.status()
            gitDiff = try await git.diff()
        } catch { self.error = error.localizedDescription }
    }

    public func commitAll(message: String) async {
        guard let root = workspace?.root else { return }
        do {
            try await GitService(root: root).commit(message: message)
            await refreshGitReview()
        } catch { self.error = error.localizedDescription }
    }

    public func send() {
        guard !isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty else { return }
        guard let profile = selectedProfile, !model.isEmpty else {
            error = "Choose a provider and model first."
            return
        }
        do { provider = try Self.makeProvider(profile, reasoning: reasoning) }
        catch { self.error = error.localizedDescription; return }
        guard let provider = provider else { return }
        let text = draft
        let images = attachedImages
        if let previous = conversationProfileID, previous != profile.id { newConversation() }
        conversationProfileID = profile.id
        let requestedModel = model
        let systemPrompt = systemPrompt
        var userParts: [ContentPart] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { userParts.append(.text(text)) }
        userParts.append(contentsOf: images.map(ContentPart.image))
        messages.append(Message(role: .user, parts: userParts))
        draft = ""
        attachedImages = []
        saveConversation()
        error = nil
        usage = nil
        estimatedCost = nil
        tokensPerSecond = nil
        let attachments = attachments
        self.attachments = []
        let iterations = maxIterations
        let workspace = workspace
        let approval = ApprovalGate(policy: approvalPolicy)
        approvalGate = approval
        isRunning = true
        runTask = Task {
            defer {
                messages = AgentSession.completingToolResults(in: messages)
                pendingEdit = nil; pendingCommand = nil; approvalGate = nil
                isRunning = false; runTask = nil; self.provider = nil
                saveConversation()
            }
            let mcpTools = await ensureMCPTools()
            let toolMap = mcpToolMap
            // The prompt describes exactly the tools this run advertises, including
            // MCP tools, so guidance and definitions can never disagree.
            let enabledToolNames = ToolRegistry.definitions(approvalIsEnabled: true).map(\.name) + mcpTools.map(\.name)
            let systemMessage = await systemMessage(attachments: attachments, tools: enabledToolNames,
                                                    agentPrompt: systemPrompt, modelID: requestedModel)
            let requestMessages = [Message(role: .system, text: systemMessage)] + messages
            // Aggregated over every provider request in this turn; tool execution time is excluded.
            var streamedOutputTokens = 0
            var streamedSeconds = 0.0
            do {
                for try await event in AgentSession().run(messages: requestMessages, model: requestedModel,
                    provider: provider, workspace: workspace, maxIterations: iterations, approval: approval,
                    extraTools: mcpTools, executeExtraTool: { call in
                        guard let mapping = toolMap[call.name] else { return nil }
                        do {
                            let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .object([:])
                            return ToolResult(callID: call.id, content: try await mapping.client.callTool(mapping.tool, arguments: arguments))
                        } catch {
                            return ToolResult(callID: call.id, content: error.localizedDescription, isError: true)
                        }
                    }) {
                    try Task.checkCancellation()
                    switch event {
                    case .message(let message):
                        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
                        else { messages.append(message) }
                    case .usage(let value, let seconds):
                        let total = TokenUsage(inputTokens: (usage?.inputTokens ?? 0) + value.inputTokens,
                                               outputTokens: (usage?.outputTokens ?? 0) + value.outputTokens)
                        usage = total
                        streamedOutputTokens += value.outputTokens
                        streamedSeconds += seconds
                        tokensPerSecond = TokenRate.tokensPerSecond(outputTokens: streamedOutputTokens, seconds: streamedSeconds)
                        estimatedCost = profile.kind != .chatGPT && requestedModel == profile.defaultModel
                            ? total.estimatedCost(inputPerMillion: profile.inputPricePerMillion, outputPerMillion: profile.outputPricePerMillion) : nil
                    case .approval(let proposal): pendingEdit = proposal
                    case .applied(let change):
                        changes.append(change)
                        workspaceRevision += 1
                    case .commandApproval(let proposal): pendingCommand = proposal
                    case .command(let command):
                        if let index = commands.firstIndex(where: { $0.id == command.id }) { commands[index] = command }
                        else { commands.append(command) }
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            // A commit may finish just as Stop cancels event delivery. Always reconcile real disk changes.
            if let workspace {
                if Task.isCancelled { await workspace.stopCommands() }
                let committed = await workspace.appliedChanges()
                let completed = await workspace.completedCommands()
                if self.workspace === workspace { changes = committed; commands = completed; workspaceRevision += 1 }
            }
        }
    }

    public func stop() {
        runTask?.cancel()
        pendingEdit = nil
        pendingCommand = nil
        if let approvalGate { Task { await approvalGate.cancel() } }
        if let provider { Task { await provider.cancel() } }
        if let workspace { Task { await workspace.stopCommands() } }
    }

    public func decideEdit(approved: Bool) {
        guard let proposal = pendingEdit, let gate = approvalGate else { return }
        pendingEdit = nil
        Task { await gate.decide(id: proposal.id, approved: approved) }
    }

    public func decideCommand(approved: Bool) {
        guard let proposal = pendingCommand, let gate = approvalGate else { return }
        pendingCommand = nil
        Task { await gate.decide(id: proposal.id, approved: approved) }
    }

    public func undoChange(_ id: UUID) async {
        guard !isBusy, let workspace, let index = changes.firstIndex(where: { $0.id == id }) else { return }
        isUndoing = true
        defer { isUndoing = false; saveConversation() }
        error = nil
        do {
            try await workspace.undoEdit(id)
            changes[index].undone = true
            workspaceRevision += 1
            // Existing tool history would otherwise tell the agent that an undone edit is still applied.
            messages.append(Message(role: .user, text: "I undid the change to \(changes[index].proposal.path). Read the current file before making further edits."))
        } catch { self.error = error.localizedDescription }
    }

    public func newConversation() {
        guard !isBusy else { return }
        startConversation(workspace: workspace)
    }

    public func newChat() {
        guard !isBusy else { return }
        startConversation(workspace: nil)
    }

    public func selectConversation(_ id: UUID) {
        guard !isBusy, id != currentConversationID else { return }
        saveConversation()
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        load(conversation)
        error = nil
        persistConfiguration()
    }

    /// Loads a conversation into the active editor, opening its workspace on demand.
    private func load(_ conversation: ChatConversation) {
        var conversation = conversation
        if conversation.workspace == nil, let path = conversation.projectPath {
            conversation.workspace = try? WorkspaceService(root: URL(fileURLWithPath: path))
        }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[index] = conversation }
        if let path = conversation.projectPath, !projectPaths.contains(path) { projectPaths.insert(path, at: 0) }
        currentConversationID = conversation.id
        workspace = conversation.workspace
        messages = conversation.messages
        draft = conversation.draft
        attachedImages = []
        conversationProfileID = conversation.profileID
        commands = conversation.commands
        changes = conversation.changes
        usage = conversation.usage
        tokensPerSecond = nil
        estimatedCost = conversation.estimatedCost
        workspaceRevision += 1
    }

    private func startConversation(workspace: WorkspaceService?) {
        saveConversation()
        let previousWorkspace = self.workspace
        self.workspace = workspace
        currentConversationID = UUID()
        messages = []; usage = nil; tokensPerSecond = nil; estimatedCost = nil; error = nil
        draft = ""; commands = []; attachedImages = []
        if previousWorkspace !== workspace { changes = [] }
        conversationProfileID = nil
        workspaceRevision += 1
        saveConversation()
        persistConfiguration()
    }

    private func saveConversation() {
        // Changes belong to the workspace, not an individual conversation.
        for index in conversations.indices where conversations[index].workspace === workspace {
            conversations[index].changes = changes
        }
        var conversation = conversations.first { $0.id == currentConversationID }
            ?? ChatConversation(id: currentConversationID, projectPath: nil, workspace: nil)
        conversation.projectPath = workspace?.root.path
        conversation.workspace = workspace
        conversation.messages = messages
        conversation.draft = draft
        conversation.profileID = conversationProfileID
        conversation.commands = commands
        conversation.changes = changes
        conversation.usage = usage
        conversation.estimatedCost = estimatedCost
        conversation.savedAt = Date()
        if let index = conversations.firstIndex(where: { $0.id == currentConversationID }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        persistConversations()
    }

    private func persistConversations() {
        do { try conversationStore.save(conversations.map(\.snapshot)) }
        catch { self.error = "Could not save conversation history: \(error.localizedDescription)" }
    }

    nonisolated public static func makeProvider(_ profile: ProviderProfile, reasoning: ReasoningEffort = .automatic) throws -> any LLMProvider {
        let keychain = KeychainStore()
        switch profile.kind {
        case .chatGPT: return ChatGPTProvider(profileID: profile.id, reasoning: reasoning)
        case .openAI, .openRouter, .openCode, .compatible:
            return try OpenAIProvider(profile: profile, apiKey: keychain.loadAPIKey(for: profile.id) ?? "", headers: keychain.loadHeaders(for: profile.id), reasoning: reasoning)
        case .openCodeConsole:
            return try OpenCodeConsoleProvider(profile: profile, apiKey: keychain.loadAPIKey(for: profile.id) ?? "",
                                               headers: keychain.loadHeaders(for: profile.id), reasoning: reasoning)
        case .anthropic:
            return try AnthropicProvider(profile: profile, apiKey: keychain.loadAPIKey(for: profile.id) ?? "", headers: keychain.loadHeaders(for: profile.id))
        }
    }

    nonisolated public static func testConnection(_ profile: ProviderProfile) async -> String {
        do {
            let models = try await makeProvider(profile).listModels()
            return "Connected. \(models.count) models available."
        } catch { return error.localizedDescription }
    }
}
