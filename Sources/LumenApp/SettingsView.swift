import LumenCore
import SwiftUI

public struct SettingsView: View {
    @Binding private var profiles: [ProviderProfile]
    @Binding private var systemPrompt: String
    @Binding private var maxIterations: Int
    private let testConnection: (@Sendable (ProviderProfile) async -> String)?

    public init(
        profiles: Binding<[ProviderProfile]>,
        systemPrompt: Binding<String>,
        maxIterations: Binding<Int>,
        testConnection: (@Sendable (ProviderProfile) async -> String)? = nil
    ) {
        _profiles = profiles
        _systemPrompt = systemPrompt
        _maxIterations = maxIterations
        self.testConnection = testConnection
    }

    public var body: some View {
        TabView {
            Form {
                ForEach($profiles) { $profile in
                    Section(profile.name) {
                        ProfileEditor(profile: $profile, testConnection: testConnection) {
                            let id = profile.id
                            profiles.removeAll { $0.id == id }
                        }
                    }
                }
                Menu("Add Provider") {
                    Button("OpenAI") {
                        profiles.append(ProviderProfile(
                            name: "OpenAI", kind: .openAI,
                            baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4.1"
                        ))
                    }
                    Button("Anthropic") {
                        profiles.append(ProviderProfile(
                            name: "Anthropic", kind: .anthropic,
                            baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-4-5"
                        ))
                    }
                    Button("OpenAI-Compatible") {
                        profiles.append(ProviderProfile(
                            name: "Local", kind: .compatible,
                            baseURL: "http://localhost:11434/v1", defaultModel: ""
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Providers", systemImage: "network") }

            Form {
                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .font(.body)
                        .frame(minHeight: 180)
                        .accessibilityLabel("System prompt")
                }
                Stepper("Maximum iterations: \(maxIterations)", value: $maxIterations, in: 1...1_000)
            }
            .formStyle(.grouped)
            .tabItem { Label("Agent", systemImage: "gearshape") }
        }
        .frame(minWidth: 580, minHeight: 520)
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
    let remove: () -> Void
    private let keychain = KeychainStore()
    @State private var apiKey = ""
    @State private var headers: [Header] = []
    @State private var status = ""
    @State private var credentialsLoaded = false
    @State private var testing = false

    var body: some View {
        Group {
            TextField("Name", text: $profile.name)
            Picker("Provider", selection: $profile.kind) {
                Text("OpenAI").tag(ProviderKind.openAI)
                Text("Anthropic").tag(ProviderKind.anthropic)
                Text("OpenAI-Compatible").tag(ProviderKind.compatible)
            }
            TextField("Base URL", text: $profile.baseURL)
            TextField("Default Model", text: $profile.defaultModel)
            TextField("Input USD / million tokens (optional)", value: $profile.inputPricePerMillion, format: .number)
            TextField("Output USD / million tokens (optional)", value: $profile.outputPricePerMillion, format: .number)

            SecureField("API Key", text: $apiKey)
                .disabled(!credentialsLoaded)
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Headers").font(.headline)
                ForEach($headers) { $header in
                    HStack {
                        TextField("Header name", text: $header.name)
                        SecureField("Header value", text: $header.value)
                        Button {
                            let id = header.id
                            headers.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel("Remove header")
                    }
                }
                Button("Add Header") { headers.append(Header(name: "", value: "")) }
                Text("Keys and custom headers are saved only in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    } catch {
                        status = error.localizedDescription
                    }
                }
                .disabled(testing)
            }
            .task(id: profile.id) {
                credentialsLoaded = false
                do {
                    apiKey = try keychain.loadAPIKey(for: profile.id) ?? ""
                    headers = try keychain.loadHeaders(for: profile.id)
                        .sorted { $0.key < $1.key }
                        .map { Header(name: $0.key, value: $0.value) }
                    credentialsLoaded = true
                } catch {
                    status = error.localizedDescription
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .textSelection(.enabled)
            }
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
