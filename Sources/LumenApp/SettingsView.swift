import AppKit
import LumenCore
import SwiftUI

public struct SettingsView: View {
    @Binding private var profiles: [ProviderProfile]
    @Binding private var systemPrompt: String
    @Binding private var maxIterations: Int
    @Binding private var reasoning: ReasoningEffort
    @Binding private var approvalPolicy: ApprovalPolicy
    @Binding private var mcpServers: [MCPServerConfig]
    private let testConnection: (@Sendable (ProviderProfile) async -> String)?
    private let stopRequests: @MainActor () -> Void
    @State private var selection: Pane?

    private enum Pane: Hashable {
        case provider(UUID)
        case agent
        case mcp
    }

    public init(
        profiles: Binding<[ProviderProfile]>,
        systemPrompt: Binding<String>,
        maxIterations: Binding<Int>,
        reasoning: Binding<ReasoningEffort>,
        approvalPolicy: Binding<ApprovalPolicy>,
        mcpServers: Binding<[MCPServerConfig]>,
        testConnection: (@Sendable (ProviderProfile) async -> String)? = nil,
        stopRequests: @escaping @MainActor () -> Void = {}
    ) {
        _profiles = profiles
        _systemPrompt = systemPrompt
        _maxIterations = maxIterations
        _reasoning = reasoning
        _approvalPolicy = approvalPolicy
        _mcpServers = mcpServers
        self.testConnection = testConnection
        self.stopRequests = stopRequests
    }

    public var body: some View {
        // One sidebar for every settings pane instead of a tab bar plus a nested
        // split view. A plain Window hosting this is resizable; contentMinSize
        // keeps the form usable.
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            if selection == nil { selection = profiles.first.map { Pane.provider($0.id) } ?? .agent }
        }
        .onChange(of: profiles.map(\.id)) { _, ids in
            guard case .provider(let id)? = selection, !ids.contains(id) else { return }
            selection = ids.first.map(Pane.provider) ?? .agent
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Providers") {
                ForEach(profiles) { profile in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name.isEmpty ? "Untitled" : profile.name)
                            Text(profile.kind.title)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "network")
                    }
                    .tag(Pane.provider(profile.id))
                }
            }
            Section {
                Label("Agent", systemImage: "slider.horizontal.3")
                    .tag(Pane.agent)
                Label("MCP Servers", systemImage: "wrench.and.screwdriver")
                    .tag(Pane.mcp)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        .safeAreaInset(edge: .bottom) { providerSidebarFooter }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .provider(let id)? where profiles.contains(where: { $0.id == id }):
            ProfileEditor(profile: profileBinding(id), testConnection: testConnection, stopRequests: stopRequests) {
                removeProfile(id)
            }
            .id(id)
        case .agent?:
            agentForm
        case .mcp?:
            mcpForm
        default:
            ContentUnavailableView("Select a setting", systemImage: "gearshape",
                                   description: Text("Choose a provider, the agent, or MCP servers."))
        }
    }

    private var providerSidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Menu {
                addProviderButton("ChatGPT Account", name: "ChatGPT", kind: .chatGPT,
                                  baseURL: "https://api.openai.com/v1", model: "")
                addProviderButton("OpenAI", name: "OpenAI", kind: .openAI,
                                  baseURL: "https://api.openai.com/v1", model: "gpt-4.1")
                addProviderButton("Anthropic", name: "Anthropic", kind: .anthropic,
                                  baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5")
                addProviderButton("OpenRouter", name: "OpenRouter", kind: .openRouter,
                                  baseURL: "https://openrouter.ai/api/v1", model: "")
                addProviderButton("OpenCode Console", name: "OpenCode", kind: .openCodeConsole,
                                  baseURL: "https://opencode.ai/console", model: "")
                addProviderButton("OpenCode Zen (legacy)", name: "OpenCode Zen", kind: .openCode,
                                  baseURL: "https://opencode.ai/zen/v1", model: "")
                addProviderButton("OpenAI-Compatible", name: "Local", kind: .compatible,
                                  baseURL: "http://localhost:11434/v1", model: "")
            } label: {
                Label("Add Provider", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, LumenStyle.space3)
            .padding(.vertical, LumenStyle.space2)
        }
        .background(.bar)
    }

    private func addProviderButton(_ title: String, name: String, kind: ProviderKind, baseURL: String, model: String) -> some View {
        Button(title) {
            let profile = ProviderProfile(name: name, kind: kind, baseURL: baseURL, defaultModel: model)
            profiles.append(profile)
            selection = .provider(profile.id)
        }
    }

    private func removeProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selection == .provider(id) { selection = profiles.first.map { Pane.provider($0.id) } ?? .agent }
    }

    /// A binding looked up by identity, so editing or removing a row never reads
    /// a stale array index (which traps during layout).
    private func profileBinding(_ id: UUID) -> Binding<ProviderProfile> {
        Binding(
            get: { profiles.first { $0.id == id } ?? ProviderProfile(name: "", kind: .openAI, baseURL: "", defaultModel: "") },
            set: { newValue in
                guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
                profiles[index] = newValue
            }
        )
    }

    private func mcpBinding(_ id: UUID) -> Binding<MCPServerConfig> {
        Binding(
            get: { mcpServers.first { $0.id == id } ?? MCPServerConfig(name: "", command: "") },
            set: { newValue in
                guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
                mcpServers[index] = newValue
            }
        )
    }

    // MARK: Agent

    private var agentForm: some View {
        Form {
            Section {
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("System prompt")
                HStack {
                    Button("Use Default Prompt") { systemPrompt = AppConfiguration.defaultSystemPrompt }
                        .disabled(systemPrompt == AppConfiguration.defaultSystemPrompt)
                    Spacer()
                }
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Sent first, followed by project instructions and environment details. \(SystemPrompt.placeholder) expands to guidance for the tools available this turn. Add AGENTS.md at the project root (or ~/.lumen) for persistent project instructions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper("Maximum agent turns: \(maxIterations)", value: $maxIterations, in: 1...1_000)
                    .help("A turn can request up to 32 tools. Independent reads can be batched; edits and commands still need individual approval.")
                Picker("Model reasoning effort", selection: $reasoning) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("Default omits the override. Supported values depend on the model and provider; an unsupported choice can reject a request.")
                Picker("Approvals", selection: $approvalPolicy) {
                    ForEach(ApprovalPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help(approvalPolicy.detail)
            } header: {
                Text("Behavior")
            } footer: {
                Text("Commands run non-interactively and are not OS-sandboxed. A built-in denylist blocks dangerous programs in every mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: MCP

    private var mcpForm: some View {
        Form {
            Section {
                if mcpServers.isEmpty {
                    Text("No MCP servers configured.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(mcpServers) { server in
                    MCPServerRow(server: mcpBinding(server.id)) {
                        mcpServers.removeAll { $0.id == server.id }
                    }
                }
                Button {
                    mcpServers.append(MCPServerConfig(name: "server", command: ""))
                } label: {
                    Label("Add MCP Server", systemImage: "plus")
                }
            } footer: {
                Text("Servers run over stdio with a scrubbed environment. Their tools are offered to the agent and run without a separate approval prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MCPServerRow: View {
    @Binding var server: MCPServerConfig
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            HStack {
                TextField("Name", text: $server.name)
                Toggle("Enabled", isOn: $server.enabled).labelsHidden()
                    .accessibilityLabel("Enable \(server.name)")
                Button("Remove", role: .destructive) { remove() }
            }
            TextField("Command (e.g. npx)", text: $server.command)
            TextField("Arguments (space-separated)", text: argumentsBinding)
        }
        .padding(.vertical, LumenStyle.space1)
    }

    private var argumentsBinding: Binding<String> {
        Binding(
            get: { server.arguments.joined(separator: " ") },
            set: { server.arguments = $0.split(separator: " ").map(String.init) }
        )
    }
}

private struct ProfileEditor: View {
    private struct Header: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    @Binding var profile: ProviderProfile
    let testConnection: (@Sendable (ProviderProfile) async -> String)?
    let stopRequests: @MainActor () -> Void
    let remove: () -> Void
    private let keychain = KeychainStore()
    @State private var apiKey = ""
    @State private var headers: [Header] = []
    @State private var status = ""
    @State private var credentialsLoaded = false
    @State private var testing = false
    @State private var account: ChatGPTAccount?
    @State private var signInTask: Task<Void, Never>?
    @State private var showPlanWelcome = false
    @State private var showRemovalWarning = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Picker("Provider", selection: $profile.kind) {
                    Text("ChatGPT Account").tag(ProviderKind.chatGPT)
                    Text("OpenAI").tag(ProviderKind.openAI)
                    Text("Anthropic").tag(ProviderKind.anthropic)
                    Text("OpenRouter").tag(ProviderKind.openRouter)
                    Text("OpenCode Zen").tag(ProviderKind.openCode)
                    Text("OpenCode Console").tag(ProviderKind.openCodeConsole)
                    Text("OpenAI-Compatible").tag(ProviderKind.compatible)
                }
                .disabled(account != nil || signInTask != nil)
            } header: {
                Text("Identity")
            } footer: {
                if account != nil || signInTask != nil {
                    Text("Sign out to change the provider type.")
                }
            }

            if profile.kind == .chatGPT {
                Section("ChatGPT Account") { chatGPTControls }
            } else {
                Section("Connection") {
                    TextField("Base URL", text: $profile.baseURL)
                    TextField("Default Model", text: $profile.defaultModel)
                    if profile.kind == .openCodeConsole {
                        captionRow("Console server. Models and their API families are read from GET /api/v2/config after you save an API key.")
                    }
                }

                Section {
                    SecureField("API Key", text: $apiKey)
                        .disabled(!credentialsLoaded)
                    customHeaders
                        .disabled(!credentialsLoaded)
                } header: {
                    Text("Credentials")
                } footer: {
                    Text("Keys and custom headers are saved only in the macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Estimated Cost") {
                    TextField("Input USD / million (optional)", value: $profile.inputPricePerMillion, format: .number)
                    TextField("Output USD / million (optional)", value: $profile.outputPricePerMillion, format: .number)
                    captionRow("Prices apply only to this profile's default model and are estimates, not billing statements.")
                }
            }

            if !status.isEmpty {
                Section {
                    Label(status, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if profile.kind != .chatGPT {
                Section {
                    actionRow
                }
            }
        }
        .formStyle(.grouped)
        .task(id: profile.id) {
            credentialsLoaded = false
            do {
                apiKey = try keychain.loadAPIKey(for: profile.id) ?? ""
                headers = try keychain.loadHeaders(for: profile.id)
                    .sorted { $0.key < $1.key }
                    .map { Header(name: $0.key, value: $0.value) }
                account = try keychain.loadChatGPTAccounts()[profile.id]
                credentialsLoaded = true
            } catch {
                status = error.localizedDescription
            }
        }
        .onDisappear { signInTask?.cancel() }
        .alert("You're using your ChatGPT plan", isPresented: $showPlanWelcome) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible requests in Lumen use your ChatGPT plan or credits, not API-key billing. Manage app access and limits in ChatGPT Settings → Usage.")
        }
        .alert("Remote sign-out was not confirmed", isPresented: $showRemovalWarning) {
            Button("Remove Account", role: .destructive) { remove() }
        } message: {
            Text("Local tokens were cleared. Disconnect Lumen in ChatGPT Settings to ensure this session cannot be renewed remotely.")
        }
    }

    private var customHeaders: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            ForEach(headers) { header in
                let binding = headerBinding(header.id)
                HStack(spacing: LumenStyle.space2) {
                    TextField("Header name", text: binding.name)
                    SecureField("Header value", text: binding.value)
                    Button {
                        headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove header")
                }
            }
            Button("Add Custom Header") { headers.append(Header(name: "", value: "")) }
        }
    }

    private var actionRow: some View {
        HStack(spacing: LumenStyle.space3) {
            Button("Save Credentials") { _ = saveCredentials() }
                .disabled(!credentialsLoaded || testing)
            if let testConnection {
                Button(testing ? "Testing…" : "Test Connection") {
                    guard saveCredentials() else { return }
                    testing = true
                    let snapshot = profile
                    Task { @MainActor in
                        status = await testConnection(snapshot)
                        testing = false
                    }
                }
                .disabled(!credentialsLoaded || testing)
            }
            Spacer(minLength: LumenStyle.space2)
            Button("Remove Provider", role: .destructive) {
                do {
                    try keychain.deleteAPIKey(for: profile.id)
                    try keychain.deleteHeaders(for: profile.id)
                    remove()
                } catch { status = error.localizedDescription }
            }
            .disabled(testing)
        }
    }

    /// A secondary explanation inside a section (SwiftUI has no plain footer slot
    /// for `Form` sections built with builders).
    private func captionRow(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func headerBinding(_ id: UUID) -> Binding<Header> {
        Binding(
            get: { headers.first { $0.id == id } ?? Header(name: "", value: "") },
            set: { newValue in
                guard let index = headers.firstIndex(where: { $0.id == id }) else { return }
                headers[index] = newValue
            }
        )
    }

    private var chatGPTControls: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space3) {
            Text("Sign in securely in your browser. No API key required. Availability and limits depend on your account and workspace.")
                .font(.callout).foregroundStyle(.secondary)
            if let account {
                Label(account.email ?? "ChatGPT account", systemImage: "person.crop.circle")
                Text("Registration · \(account.clientID.suffix(8))").font(.caption).foregroundStyle(.secondary)
                Text(account.tokens == nil ? "Signed out" : "Using ChatGPT plan").font(.caption)
            }
            HStack {
                Button("Continue with ChatGPT") {
                    let id = profile.id
                    let firstSignIn = account == nil
                    signInTask = Task { @MainActor in
                        defer { signInTask = nil }
                        do {
                            let signedIn = try await ChatGPTAuthorization.shared.signIn(profileID: id) { NSWorkspace.shared.open($0) }
                            account = signedIn
                            profile.name = "ChatGPT · \(signedIn.email ?? "Account") · \(signedIn.clientID.suffix(6))"
                            status = "Connected with your ChatGPT plan. Select this account in the chat composer."
                            showPlanWelcome = firstSignIn
                        } catch {
                            if !Task.isCancelled { status = error.localizedDescription }
                        }
                    }
                }
                .disabled(signInTask != nil || testing)
                if signInTask != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { signInTask?.cancel() }
                }
                if account?.tokens != nil {
                    Button("Sign Out") { disconnect(removeProfile: false) }
                        .disabled(signInTask != nil || testing)
                }
                Spacer()
                Button("Remove Account", role: .destructive) { disconnect(removeProfile: true) }
                    .disabled(signInTask != nil || testing)
            }
            TextField("Default model (optional)", text: $profile.defaultModel)
            if let testConnection {
                Button(testing ? "Testing…" : "Test Connection") {
                    testing = true
                    let snapshot = profile
                    Task { @MainActor in status = await testConnection(snapshot); testing = false }
                }
                .disabled(account?.tokens == nil || testing || signInTask != nil)
            }
            Link("Manage usage and app access", destination: ChatGPTAuthorization.usageURL)
            Text("Tokens stay in the macOS Keychain. Lumen uses OpenAI's public Responses API.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func disconnect(removeProfile: Bool) {
        stopRequests()
        testing = true
        let id = profile.id
        Task { @MainActor in
            defer { testing = false }
            do {
                let revoked = try await ChatGPTAuthorization.shared.signOut(profileID: id, remove: removeProfile)
                account = try keychain.loadChatGPTAccounts()[id]
                status = revoked ? "Signed out." : "Signed out locally. Remote revocation was not confirmed; disconnect Lumen in ChatGPT Settings."
                if removeProfile {
                    if revoked { remove() } else { showRemovalWarning = true }
                }
            } catch { status = error.localizedDescription }
        }
    }

    private func saveCredentials() -> Bool {
        var values: [String: String] = [:]
        var names: Set<String> = []
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy(allowed.contains),
                  !header.value.contains("\r"), !header.value.contains("\n"),
                  names.insert(name.lowercased()).inserted else {
                status = "Headers must have valid, unique names and single-line values."
                return false
            }
            values[name] = header.value
        }
        do {
            if apiKey.isEmpty {
                try keychain.deleteAPIKey(for: profile.id)
            } else {
                try keychain.saveAPIKey(apiKey, for: profile.id)
            }
            if values.isEmpty {
                try keychain.deleteHeaders(for: profile.id)
            } else {
                try keychain.saveHeaders(values, for: profile.id)
            }
            status = "Credentials saved."
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }
}

private extension ProviderKind {
    /// A short, human-readable label for the provider list.
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .chatGPT: "ChatGPT Account"
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode Zen"
        case .openCodeConsole: "OpenCode Console"
        case .compatible: "OpenAI-Compatible"
        }
    }
}
