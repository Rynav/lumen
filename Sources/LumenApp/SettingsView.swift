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
        TabView {
            providersTab
                .tabItem { Label("Providers", systemImage: "network") }
            agentTab
                .tabItem { Label("Agent", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 640, height: 560)
    }

    // MARK: Providers

    private var providersTab: some View {
        Form {
            if profiles.isEmpty {
                Section {
                    ContentUnavailableView("Connect your first provider", systemImage: "network",
                                           description: Text("Add a provider below to start a conversation. Credentials stay in the macOS Keychain."))
                }
            }
            ForEach(profiles) { profile in
                Section(profile.name) {
                    ProfileEditor(profile: profileBinding(profile.id), testConnection: testConnection, stopRequests: stopRequests) {
                        profiles.removeAll { $0.id == profile.id }
                    }
                }
            }
            Section {
                Menu {
                    providerMenuButton("ChatGPT Account", name: "ChatGPT", kind: .chatGPT,
                                       baseURL: "https://api.openai.com/v1", model: "")
                    providerMenuButton("OpenAI", name: "OpenAI", kind: .openAI,
                                       baseURL: "https://api.openai.com/v1", model: "gpt-4.1")
                    providerMenuButton("Anthropic", name: "Anthropic", kind: .anthropic,
                                       baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5")
                    providerMenuButton("OpenRouter", name: "OpenRouter", kind: .openRouter,
                                       baseURL: "https://openrouter.ai/api/v1", model: "")
                    providerMenuButton("OpenCode Zen", name: "OpenCode", kind: .openCode,
                                       baseURL: "https://opencode.ai/zen/v1", model: "")
                    providerMenuButton("OpenAI-Compatible", name: "Local", kind: .compatible,
                                       baseURL: "http://localhost:11434/v1", model: "")
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func providerMenuButton(_ title: String, name: String, kind: ProviderKind, baseURL: String, model: String) -> some View {
        Button(title) {
            profiles.append(ProviderProfile(name: name, kind: kind, baseURL: baseURL, defaultModel: model))
        }
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

    private var agentTab: some View {
        Form {
            Section("System Prompt") {
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
                Text("Lumen sends this, then project instructions and environment details, as the first message. Where \(SystemPrompt.placeholder) appears, guidance for the tools available in that turn is inserted automatically. Lumen replaces this prompt with a model-specific one for GPT models, and appends code-comment guidance for Claude models.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Add an AGENTS.md at your project root (or one in ~/.lumen) to give Lumen persistent project instructions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Stepper("Maximum agent turns: \(maxIterations)", value: $maxIterations, in: 1...1_000)
                Text("A turn can request up to 32 tools. Independent reads can be requested together; edits and commands still need individual approval.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Model reasoning effort", selection: $reasoning) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Default omits the override. Supported effort values depend on the model and provider; an unsupported choice can reject a request.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Approvals", selection: $approvalPolicy) {
                    ForEach(ApprovalPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(approvalPolicy.detail)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Commands run non-interactively and are not OS-sandboxed. A built-in denylist blocks dangerous programs in every mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MCP Servers") {
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
        Group {
            TextField("Name", text: $profile.name)
            Picker("Provider", selection: $profile.kind) {
                Text("ChatGPT Account").tag(ProviderKind.chatGPT)
                Text("OpenAI").tag(ProviderKind.openAI)
                Text("Anthropic").tag(ProviderKind.anthropic)
                Text("OpenRouter").tag(ProviderKind.openRouter)
                Text("OpenCode").tag(ProviderKind.openCode)
                Text("OpenAI-Compatible").tag(ProviderKind.compatible)
            }
            .disabled(account != nil || signInTask != nil)

            if profile.kind == .chatGPT {
                chatGPTControls
            } else {
                TextField("Base URL", text: $profile.baseURL)
                TextField("Default Model", text: $profile.defaultModel)
                TextField("Input USD / million (optional)", value: $profile.inputPricePerMillion, format: .number)
                TextField("Output USD / million (optional)", value: $profile.outputPricePerMillion, format: .number)
                SecureField("API Key", text: $apiKey)
                    .disabled(!credentialsLoaded)

                customHeaders
                    .disabled(!credentialsLoaded)

                HStack {
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
                    Spacer()
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
            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
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
            Text("Custom Headers").font(.caption).foregroundStyle(.secondary)
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
            Button("Add Header") { headers.append(Header(name: "", value: "")) }
            Text("Keys and custom headers are saved only in the macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
