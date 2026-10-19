import Foundation
import Testing
@testable import LumenCore

/// Serves one workspace config and the streaming bodies its routes point at, and
/// records what Lumen requested. Live network stays out of the tests.
final class ConsoleFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        var path: String
        var authorization: String?
        var apiKey: String?
        var organization: String?
    }

    final class Workspace: @unchecked Sendable {
        let host = "console-\(UUID().uuidString.lowercased()).invalid"
        private let build: @Sendable (String) -> String
        private let lock = NSLock()
        private var entries: [Recorded] = []

        init(config: @escaping @Sendable (String) -> String) { build = config }
        var server: String { "https://\(host)/console" }
        var config: String { build(host) }
        var requests: [Recorded] { lock.withLock { entries } }
        func append(_ entry: Recorded) { lock.withLock { entries.append(entry) } }
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var workspaces: [String: Workspace] = [:]
        func insert(_ workspace: Workspace) { lock.withLock { workspaces[workspace.host] = workspace } }
        func remove(_ host: String) { lock.withLock { workspaces[host] = nil } }
        func get(_ host: String) -> Workspace? { lock.withLock { workspaces[host] } }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let workspace = Self.registry.get(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        workspace.append(Recorded(
            path: url.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            apiKey: request.value(forHTTPHeaderField: "x-api-key"),
            organization: request.value(forHTTPHeaderField: "x-opencode-org-id")))
        let path = url.path
        let (body, type): (String, String)
        if path.hasSuffix("/api/v2/config") {
            (body, type) = (workspace.config, "application/json")
        } else if path.hasSuffix("/chat/completions") {
            (body, type) = (Self.chatStream, "text/event-stream")
        } else if path.hasSuffix("/responses") {
            (body, type) = (Self.responsesStream, "text/event-stream")
        } else if path.hasSuffix("/messages") {
            (body, type) = (Self.messagesStream, "text/event-stream")
        } else {
            (body, type) = ("{}", "application/json")
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static let chatStream = """
    data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]


    """

    static let responsesStream = """
    data: {"type":"response.completed","response":{"status":"completed"}}


    """

    static let messagesStream = """
    data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

    data: {"type":"message_stop"}


    """
}

@Suite struct ConsoleCatalogTests {
    static func config(host: String) -> String {
        """
        {
          "providers": {
            "opencode": {
              "name": "OpenCode",
              "env": ["OPENCODE_CONSOLE_TOKEN"],
              "package": "aisdk:@ai-sdk/openai-compatible",
              "settings": {
                "baseURL": "https://\(host)/inference/openai/v1",
                "apiKey": "{env:OPENCODE_CONSOLE_TOKEN}"
              },
              "headers": { "x-opencode-org-id": "org_test" },
              "models": {
                "kimi-k2.6": { "name": "Kimi K2.6", "cost": [ { "input": 0, "output": 0 } ] },
                "claude-sonnet-4-6": { "name": "Claude Sonnet 4.6", "package": "aisdk:@ai-sdk/anthropic", "cost": [ { "input": 3, "output": 15 }, { "input": 6, "output": 22.5, "tier": 200000 } ] },
                "gpt-5": { "name": "GPT-5", "package": "aisdk:@ai-sdk/openai" },
                "gemini-3-flash": { "name": "Gemini 3 Flash", "package": "aisdk:@ai-sdk/google" },
                "retired": { "name": "Retired", "disabled": true }
              }
            },
            "deepseek": {
              "name": "DeepSeek",
              "package": "aisdk:@ai-sdk/openai-compatible",
              "settings": { "baseURL": "https://\(host)/inference/custom/conn_deepseek" },
              "models": { "deepseek-chat": { "name": "DeepSeek Chat" } }
            }
          }
        }
        """
    }

    @Test func parsesEveryFamilyAndDerivesItsBase() throws {
        let catalog = try ConsoleCatalog.parse(Data(Self.config(host: "console.example.invalid").utf8))
        #expect(catalog.headers == ["x-opencode-org-id": "org_test"])
        #expect(catalog.models["kimi-k2.6"] == ConsoleModel(endpoint: .chat, baseURL: "https://console.example.invalid/inference/openai/v1", name: "Kimi K2.6", isFree: true))
        #expect(catalog.models["claude-sonnet-4-6"] == ConsoleModel(endpoint: .messages, baseURL: "https://console.example.invalid/inference/anthropic/v1", name: "Claude Sonnet 4.6", isFree: false))
        #expect(catalog.models["gpt-5"] == ConsoleModel(endpoint: .responses, baseURL: "https://console.example.invalid/inference/openai/v1", name: "GPT-5", isFree: false))
        #expect(catalog.models["gemini-3-flash"]?.endpoint == .google)
        #expect(catalog.models["deepseek-chat"]?.baseURL == "https://console.example.invalid/inference/custom/conn_deepseek")
        #expect(catalog.models["retired"] == nil)
    }

    @Test func rejectsAConfigWithoutProviders() throws {
        #expect(throws: ProviderError.unsupported("OpenCode Console returned no providers. Check the server URL and this key's permissions.")) {
            try ConsoleCatalog.parse(Data(#"{"providers": 3}"#.utf8))
        }
    }

    @Test func explainsTheFreeTierRejection() {
        let body = Data(#"{"type":"error","error":{"type":"FreeTierError","message":"Free tier is limited to OpenCode."}}"#.utf8)
        #expect(HTTPTransport.responseError(status: 403, body: body)
            == .unsupported("Free OpenCode models work only in the OpenCode client. Choose a paid model from this workspace, or add credits at opencode.ai/console."))
    }

    @Test func fetchesTheConfigWithTheConsoleKey() async throws {
        let workspace = ConsoleFixtureProtocol.Workspace { ConsoleCatalogTests.config(host: $0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsoleFixtureProtocol.self]
        ConsoleFixtureProtocol.registry.insert(workspace)
        defer { ConsoleFixtureProtocol.registry.remove(workspace.host) }

        let catalog = try await ConsoleCatalog.fetch(
            server: workspace.server, apiKey: "oc_sk_test",
            transport: HTTPTransport(configuration: config))

        #expect(catalog.models.count == 5)
        let request = try #require(workspace.requests.first)
        #expect(request.path == "/console/api/v2/config")
        #expect(request.authorization == "Bearer oc_sk_test")
    }
}

@Suite struct ModelInfoTests {
    private struct Stub: LLMProvider {
        func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func listModels() async throws -> [String] { ["b", "a"] }
        func cancel() async {}
    }

    @Test func providersWithoutACatalogOfferBareIDs() async throws {
        #expect(try await Stub().modelInfo() == [ModelInfo(id: "b"), ModelInfo(id: "a")])
    }
}

@Suite struct OpenCodeConsoleProviderTests {
    private func fixture() -> (ConsoleFixtureProtocol.Workspace, OpenCodeConsoleProvider) {
        let workspace = ConsoleFixtureProtocol.Workspace { ConsoleCatalogTests.config(host: $0) }
        ConsoleFixtureProtocol.registry.insert(workspace)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsoleFixtureProtocol.self]
        let profile = ProviderProfile(name: "OpenCode", kind: .openCodeConsole, baseURL: workspace.server, defaultModel: "")
        return (workspace, OpenCodeConsoleProvider(profile: profile, apiKey: "oc_sk_test", configuration: config))
    }

    private func events(_ provider: any LLMProvider, model: String) async throws -> [StreamEvent] {
        var output: [StreamEvent] = []
        for try await event in provider.stream(messages: [Message(role: .user, text: "hi")], model: model, tools: []) {
            output.append(event)
        }
        return output
    }

    @Test func routesEachModelToItsFamilyPath() async throws {
        let (workspace, provider) = fixture()
        defer { ConsoleFixtureProtocol.registry.remove(workspace.host) }

        #expect(try await provider.listModels() == ["claude-sonnet-4-6", "deepseek-chat", "gpt-5", "kimi-k2.6"])
        #expect(try await events(provider, model: "kimi-k2.6") == [.text("ok"), .finished])
        #expect(try await events(provider, model: "gpt-5") == [.finished])
        #expect(try await events(provider, model: "claude-sonnet-4-6") == [.text("ok"), .finished])

        let requests = workspace.requests
        #expect(requests.filter { $0.path == "/console/api/v2/config" }.count == 1)
        #expect(requests.contains { $0.path == "/inference/openai/v1/chat/completions" })
        #expect(requests.contains { $0.path == "/inference/openai/v1/responses" })
        #expect(requests.contains { $0.path == "/inference/anthropic/v1/messages" })
        #expect(requests.allSatisfy { $0.authorization == "Bearer oc_sk_test" })
        #expect(requests.filter { $0.path.hasPrefix("/inference/") }.allSatisfy { $0.organization == "org_test" })
        #expect(requests.first { $0.path.hasSuffix("/messages") }?.apiKey == "oc_sk_test")
    }

    @Test func offersNamedModelsWithPricesAndHidesGemini() async throws {
        let (workspace, provider) = fixture()
        defer { ConsoleFixtureProtocol.registry.remove(workspace.host) }

        let models = try await provider.modelInfo()
        #expect(models.map(\.id) == ["claude-sonnet-4-6", "deepseek-chat", "gpt-5", "kimi-k2.6"])
        #expect(models.map(\.label) == ["Claude Sonnet 4.6", "DeepSeek Chat", "GPT-5", "Kimi K2.6"])
        #expect(models.first { $0.id == "kimi-k2.6" }?.isFree == true)
        #expect(models.first { $0.id == "claude-sonnet-4-6" }?.isFree == false)
    }

    @Test func rejectsModelsLumenCannotServe() async throws {
        let (workspace, provider) = fixture()
        defer { ConsoleFixtureProtocol.registry.remove(workspace.host) }

        do {
            _ = try await events(provider, model: "gemini-3-flash")
            Issue.record("Expected Gemini to be rejected")
        } catch let error as ProviderError {
            #expect(error.errorDescription?.contains("Gemini") == true)
        }
        do {
            _ = try await events(provider, model: "unknown")
            Issue.record("Expected an unknown model to be rejected")
        } catch let error as ProviderError {
            #expect(error.errorDescription?.contains("not available") == true)
        }
    }
}

@Suite struct ResponsesBodyTests {
    private let tools = [ToolDefinition(name: "read_file", description: "Read a file",
                                        parameters: .object(["type": .string("object")]))]
    private var history: [Message] {
        [Message(role: .assistant, parts: [.toolCall(ToolCall(id: "c1", name: "read_file", arguments: "{}"))])]
    }

    private func body(model: String, namespacedTools: Bool = false) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: ChatGPTProvider.requestBody(
            messages: history, model: model, tools: tools, namespacedTools: namespacedTools))
    }

    @Test func flatFunctionsAndReplayedCallsOmitTheNamespace() throws {
        let body = try body(model: "gpt-5")
        #expect(body["tools"]?.array?.first?["type"]?.string == "function")
        #expect(body["tools"]?.array?.first?["namespace"] == nil)
        #expect(body["input"]?.array?.first?["namespace"] == nil)
        #expect(body["include"] != nil)
    }

    @Test func nonReasoningModelsOmitEncryptedReasoning() throws {
        let body = try body(model: "grok-4.7")
        #expect(body["include"] == nil)
        #expect(body["reasoning"] == nil)
    }

    @Test func chatGPTPlanKeepsNamespacedTools() throws {
        let body = try body(model: "gpt-5", namespacedTools: true)
        #expect(body["tools"]?.array?.first?["type"]?.string == "namespace")
        #expect(body["input"]?.array?.first?["namespace"]?.string == "workspace")
    }
}
