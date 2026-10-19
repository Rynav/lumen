import Foundation

/// OpenCode Console serves one API family per model, one path per family, and
/// rejects a model on another family's path. The workspace config names each
/// model's family, so it is read once per provider (one per turn) and reused.
public final class OpenCodeConsoleProvider: LLMProvider, @unchecked Sendable {
    private let profile: ProviderProfile
    private let apiKey: String
    private let headers: [String: String]
    private let reasoning: ReasoningEffort
    private let configuration: URLSessionConfiguration
    private let transport: HTTPTransport
    private let lock = NSLock()
    private var catalog: ConsoleCatalog?
    private var active: (any LLMProvider)?
    private var cancelled = false

    public convenience init(profile: ProviderProfile, apiKey: String, headers: [String: String] = [:], reasoning: ReasoningEffort = .automatic) {
        self.init(profile: profile, apiKey: apiKey, headers: headers, reasoning: reasoning, configuration: .ephemeral)
    }

    init(profile: ProviderProfile, apiKey: String, headers: [String: String] = [:], reasoning: ReasoningEffort = .automatic,
         configuration: URLSessionConfiguration) {
        self.profile = profile
        self.apiKey = apiKey
        self.headers = headers
        self.reasoning = reasoning
        self.configuration = configuration
        transport = HTTPTransport(configuration: configuration)
    }

    deinit { transport.cancel() }

    public func cancel() async {
        let provider: (any LLMProvider)? = lock.withLock {
            cancelled = true
            defer { active = nil }
            return active
        }
        transport.cancel()
        await provider?.cancel()
    }

    public func listModels() async throws -> [String] {
        try await modelInfo().map(\.id)
    }

    /// The workspace catalog already carries names and prices, so the picker can
    /// show "Kimi K2.6 · Free" instead of a bare id.
    public func modelInfo() async throws -> [ModelInfo] {
        let models = try await workspace().models
        // Lumen has no Gemini client; do not offer a model that can only fail.
        return models.filter { $0.value.endpoint != .google }
            .map { ModelInfo(id: $0.key, name: $0.value.name, isFree: $0.value.isFree) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    public func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let catalog = try await workspace()
                    guard let route = catalog.models[model] else {
                        throw ProviderError.unsupported("\(model) is not available in this OpenCode Console workspace. Refresh the model list and pick one from it.")
                    }
                    let provider = try delegate(for: route, catalog: catalog)
                    guard activate(provider) else { throw CancellationError() }
                    for try await event in provider.stream(messages: messages, model: model, tools: tools) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable termination in
                task.cancel()
                // A normal step finish must leave the provider usable for the next tool step.
                guard case .cancelled = termination else { return }
                Task { await self.cancel() }
            }
        }
    }

    private func workspace() async throws -> ConsoleCatalog {
        if let catalog = lock.withLock({ self.catalog }) { return catalog }
        let fetched = try await ConsoleCatalog.fetch(server: profile.baseURL, apiKey: apiKey, headers: headers, transport: transport)
        lock.withLock { if catalog == nil { catalog = fetched } }
        return fetched
    }

    private func activate(_ provider: any LLMProvider) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            active = provider
            return true
        }
    }

    private func delegate(for route: ConsoleModel, catalog: ConsoleCatalog) throws -> any LLMProvider {
        let console = ProviderProfile(name: profile.name, kind: .compatible, baseURL: route.baseURL, defaultModel: profile.defaultModel)
        // Config headers (e.g. x-opencode-org-id) apply to every gateway request.
        var headers = headers
        for (name, value) in catalog.headers { headers[name] = value }
        switch route.endpoint {
        case .chat:
            return try OpenAIProvider(profile: console, apiKey: apiKey, headers: headers,
                                      transport: HTTPTransport(configuration: configuration), reasoning: reasoning)
        case .responses:
            return try ResponsesProvider(baseURL: route.baseURL, apiKey: apiKey, headers: headers,
                                         transport: HTTPTransport(configuration: configuration), reasoning: reasoning)
        case .messages:
            // Console documents Bearer for inference while the Anthropic wire format uses
            // x-api-key, so both carry the same key.
            if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
            return try AnthropicProvider(profile: console, apiKey: apiKey, headers: headers,
                                         transport: HTTPTransport(configuration: configuration))
        case .google:
            throw ProviderError.unsupported("Gemini models need a client Lumen does not have. Pick another model from this OpenCode Console workspace.")
        }
    }
}
