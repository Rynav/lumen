import Foundation
import Testing
@testable import LumenCore

@Suite struct ProviderTests {
    private func events(_ bytes: [UInt8]) throws -> [SSEParser.Event] {
        var parser = SSEParser()
        var output: [SSEParser.Event] = []
        for byte in bytes {
            if let event = try parser.consume(byte) { output.append(event) }
        }
        try parser.finish()
        return output
    }

    @Test func sseFramingAndUTF8() throws {
        let input = "\u{FEFF}: heartbeat\r\nevent: message\r\nid: ignored\r\ndata: hé🌍\r\ndata:  second\r\n\r\n: ping\n\ndata\n\ndata: third\r\r"
        #expect(try events(Array(input.utf8)) == [
            SSEParser.Event(event: "message", data: "hé🌍\n second"),
            SSEParser.Event(event: nil, data: ""),
            SSEParser.Event(event: nil, data: "third")
        ])
    }

    @Test func malformedAndTruncatedSSE() throws {
        #expect(throws: ProviderError.malformedStream) {
            try events(Array("data: ".utf8) + [0xFF, 10, 10])
        }
        #expect(throws: ProviderError.malformedStream) {
            try events(Array("data: ".utf8) + [0xF0, 0x9F])
        }
        #expect(throws: ProviderError.incompleteStream) { try events(Array("data: unfinished".utf8)) }
        #expect(throws: ProviderError.incompleteStream) { try events(Array("data: unfinished\n".utf8)) }
    }

    @Test func textUsageAndCompletion() throws {
        let fixture = """
        : keepalive

        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hello 🌍"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}

        data: [DONE]


        """
        var decoder = OpenAIProvider.StreamDecoder()
        let decoded = try events(Array(fixture.utf8)).flatMap { try decoder.consume($0.data) }
        try decoder.finish()
        #expect(decoded == [.text("Hello 🌍"), .usage(TokenUsage(inputTokens: 12, outputTokens: 3)), .finished])
    }

    @Test func indexedToolsAreAggregatedBeforeEmission() throws {
        var decoder = OpenAIProvider.StreamDecoder()
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"run_","arguments":"{"}},{"index":0,"id":"call_a","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#).isEmpty)
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"README.md\"}"}},{"index":1,"function":{"name":"command","arguments":"\"command\":\"pwd\"}"}}]}}]}"#).isEmpty)
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#) == [
            .toolCall(ToolCall(id: "call_a", name: "read_file", arguments: #"{"path":"README.md"}"#)),
            .toolCall(ToolCall(id: "call_b", name: "run_command", arguments: #"{"command":"pwd"}"#))
        ])
        #expect(try decoder.consume("[DONE]") == [.finished])
        try decoder.finish()
    }

    @Test func invalidAndIncompleteOpenAIChunks() throws {
        var decoder = OpenAIProvider.StreamDecoder()
        #expect(throws: ProviderError.malformedStream) { try decoder.consume("not json") }
        #expect(throws: ProviderError.malformedStream) { try decoder.consume("{}") }
        #expect(throws: ProviderError.incompleteStream) { try decoder.consume("[DONE]") }
        #expect(throws: ProviderError.incompleteStream) { try decoder.finish() }
        _ = try decoder.consume(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f","arguments":"{"}}]}}]}"#)
        #expect(throws: ProviderError.malformedStream) {
            try decoder.consume(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)
        }
        var finished = OpenAIProvider.StreamDecoder()
        _ = try finished.consume(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
        #expect(throws: ProviderError.incompleteStream) { try finished.finish() }
    }

    @Test func openRouterDuplicateFinishWithUsageIsAccepted() throws {
        // Captured from deepseek/deepseek-v4.1-flash: OpenRouter repeats finish_reason on the usage chunk.
        var decoder = OpenAIProvider.StreamDecoder()
        _ = try decoder.consume(#"{"choices":[{"index":0,"delta":{"content":null,"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"list_files","arguments":""}}]}}]}"#)
        _ = try decoder.consume(#"{"choices":[{"index":0,"delta":{"content":null,"role":"assistant","tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\".\"}"}}]}}]}"#)
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"tool_calls"}]}"#) == [
            .toolCall(ToolCall(id: "call_1", name: "list_files", arguments: #"{"path":"."}"#))
        ])
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":428,"completion_tokens":49}}"#) == [
            .usage(TokenUsage(inputTokens: 428, outputTokens: 49))
        ])
        #expect(try decoder.consume("[DONE]") == [.finished])
        try decoder.finish()
    }

    @Test func requestEncodingAndEndpoints() throws {
        let provider = try OpenAIProvider(profile: profile(), apiKey: "secret", headers: ["X-Custom": "value", "authorization": "wrong"])
        let call = ToolCall(id: "call_a", name: "read_file", arguments: #"{"path":"a"}"#)
        let data = try OpenAIProvider.requestBody(messages: [
            Message(role: .system, text: "Help"), Message(role: .user, text: "Read a"),
            Message(role: .assistant, parts: [.toolCall(call)]),
            Message(role: .tool, parts: [.toolResult(ToolResult(callID: "call_a", content: "Contents"))])
        ], model: "gpt-test", tools: [ToolDefinition(name: "read_file", description: "Read", parameters: .object(["type": .string("object")]))])
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["model"] == .string("gpt-test"))
        #expect(value["stream"] == .bool(true))
        #expect(value["stream_options"]?["include_usage"] == .bool(true))
        #expect(value["messages"]?.array?[2]["tool_calls"]?.array?.first?["id"] == .string("call_a"))
        #expect(value["messages"]?.array?[3]["tool_call_id"] == .string("call_a"))
        #expect(value["tools"]?.array?.first?["function"]?["name"] == .string("read_file"))
        let request = provider.request(path: "chat/completions", body: data)
        #expect(request.url?.absoluteString == "https://fixture.invalid/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
        #expect(provider.request(path: "models").url?.path == "/v1/models")
    }

    @Test func imagePartsEncodeAsDataURLs() throws {
        let image = ImageAttachment(mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let data = try OpenAIProvider.requestBody(messages: [
            Message(role: .user, parts: [.text("Look"), .image(image)])
        ], model: "gpt-test", tools: [])
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let content = value["messages"]?.array?.first?["content"]?.array
        #expect(content?[0]["type"] == .string("text"))
        #expect(content?[1]["type"] == .string("image_url"))
        #expect(content?[1]["image_url"]?["url"] == .string(image.dataURL))
        #expect(image.dataURL == "data:image/png;base64,\(image.data.base64EncodedString())")

        // An image-only turn still produces a message, with just the image block.
        let imageOnly = try OpenAIProvider.requestBody(messages: [
            Message(role: .user, parts: [.image(image)])
        ], model: "gpt-test", tools: [])
        let only = try JSONDecoder().decode(JSONValue.self, from: imageOnly)["messages"]?.array?.first?["content"]?.array
        #expect(only?.count == 1)
        #expect(only?[0]["type"] == .string("image_url"))
    }

    @Test func imagePartsRoundTripThroughCodable() throws {
        let message = Message(role: .user, parts: [.text("hi"), .image(ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3])))])
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
        #expect(decoded.images.count == 1)
    }

    @Test func untrustedConfigurationAndSafeErrors() throws {
        for url in ["file:///etc/passwd", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com#secret"] {
            #expect(throws: ProviderError.invalidURL) { try HTTPTransport.baseURL(url) }
        }
        #expect(throws: ProviderError.self) { try OpenAIProvider(profile: profile(), apiKey: "secret\r\nInjected: yes") }
        #expect(throws: ProviderError.self) { try OpenAIProvider(profile: profile(), apiKey: "secret", headers: ["X-Test": "value\nInjected: yes"]) }
        #expect(throws: ProviderError.self) { try HTTPTransport.validateHeaders(["Bad\r\nName": "value"]) }
        let secret = Data(#"{"error":{"message":"secret must not escape","code":"context_length_exceeded"}}"#.utf8)
        #expect(HTTPTransport.responseError(status: 400, body: secret) == .contextLength)
        #expect(HTTPTransport.responseError(status: 401, body: secret) == .unauthorized)
        #expect(HTTPTransport.responseError(status: 403, body: secret) == .unauthorized)
        #expect(HTTPTransport.responseError(status: 429, body: secret) == .rateLimited)
        #expect(HTTPTransport.responseError(status: 500, body: Data("secret".utf8)) == .http(500))
        #expect(HTTPTransport.retryDelay(attempt: 0, retryAfter: nil) == 1)
        #expect(HTTPTransport.retryDelay(attempt: 2, retryAfter: "0") == 4)
        #expect(HTTPTransport.retryDelay(attempt: 0, retryAfter: "999999") == 60)
        #expect(HTTPTransport.retryDelay(attempt: 0, retryAfter: "Thu, 01 Jan 1970 00:00:10 GMT", now: Date(timeIntervalSince1970: 0)) == 10)
    }

    private func profile() -> ProviderProfile {
        ProviderProfile(name: "Fixture", kind: .openAI, baseURL: "https://fixture.invalid/v1/", defaultModel: "test")
    }
}

/// Scripted URLProtocol responses keep transport and retry tests offline.
/// Stream cancellation needs a live socket: see `StreamingFixtureServer`.
final class ProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        var error: URLError?
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply]
        private var count = 0
        init(_ replies: [Reply]) { self.replies = replies }
        var requestCount: Int { lock.withLock { count } }
        func next() -> Reply {
            lock.withLock {
                count += 1
                return replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
            }
        }
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [String: Script] = [:]
        func set(_ script: Script?, for id: String) { lock.withLock { scripts[id] = script } }
        func get(_ id: String) -> Script? { lock.withLock { scripts[id] } }
    }

    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture"), let script = Self.registry.get(id),
              let url = request.url else { return }
        let reply = script.next()
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct OpenAITransportTests {
    private func fixture(_ replies: [ProviderFixtureProtocol.Reply]) throws -> (OpenAIProvider, ProviderFixtureProtocol.Script, String) {
        let id = UUID().uuidString
        let script = ProviderFixtureProtocol.Script(replies)
        ProviderFixtureProtocol.registry.set(script, for: id)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderFixtureProtocol.self]
        let provider = try OpenAIProvider(
            profile: ProviderProfile(name: "Fixture", kind: .openAI, baseURL: "https://fixture.invalid/v1", defaultModel: "test"),
            apiKey: "test-only", headers: ["X-Fixture": id], transport: HTTPTransport(configuration: config)
        )
        return (provider, script, id)
    }

    private func profile(baseURL: String) -> ProviderProfile {
        ProviderProfile(name: "Fixture", kind: .openAI, baseURL: baseURL, defaultModel: "test")
    }

    @Test func modelListingRetriesAndPreservesNetworkErrors() async throws {
        let (provider, script, id) = try fixture([
            .init(status: 429, headers: ["Retry-After": "0"]),
            .init(body: #"{"data":[{"id":"z"},{"id":"a"},{"id":"a"}]}"#),
            .init(error: URLError(.notConnectedToInternet))
        ])
        defer { ProviderFixtureProtocol.registry.set(nil, for: id) }
        #expect(try await provider.listModels() == ["a", "z"])
        #expect(script.requestCount == 2)
        do {
            _ = try await provider.listModels()
            Issue.record("Expected a network error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
        #expect(script.requestCount == 3)
    }

    @Test func explicitCancellationAndReuse() async throws {
        let server = try StreamingFixtureServer()
        defer { server.stop() }
        let provider = try OpenAIProvider(profile: profile(baseURL: try await server.baseURL()), apiKey: "test-only")
        var output: [StreamEvent] = []
        do {
            for try await event in provider.stream(messages: [], model: "test", tools: []) {
                output.append(event)
                await provider.cancel()
            }
            Issue.record("Expected stream cancellation")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(output == [.text("hello")])
        #expect(try await provider.listModels() == ["reused"])
        #expect(server.requestCount == 2)
    }

    @Test func consumerCancellationTerminatesStream() async throws {
        let server = try StreamingFixtureServer()
        defer { server.stop() }
        let provider = try OpenAIProvider(profile: profile(baseURL: try await server.baseURL()), apiKey: "test-only")
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            do {
                for try await _ in provider.stream(messages: [], model: "test", tools: []) { signal.yield(()) }
            } catch {
                #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
        }
        for await _ in started { break }
        task.cancel()
        await task.value
        signal.finish()
    }

    @Test func partialStreamIsNeverRetried() async throws {
        let (provider, script, id) = try fixture([
            .init(body: "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\ndata: {\"error\":{\"message\":\"secret\"}}\n\n")
        ])
        defer { ProviderFixtureProtocol.registry.set(nil, for: id) }
        var output: [StreamEvent] = []
        do {
            for try await event in provider.stream(messages: [], model: "test", tools: []) { output.append(event) }
            Issue.record("Expected stream failure")
        } catch let error as ProviderError {
            #expect(error == .http(400))
        }
        #expect(output == [.text("partial")])
        #expect(script.requestCount == 1)
    }
}
