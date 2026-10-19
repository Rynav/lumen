import Foundation

/// The OpenAI Responses API with a bearer key, for gateways that serve GPT-style
/// models on their own path (OpenCode Console, api.openai.com). Tools are flat
/// functions; the ChatGPT plan's namespaced form is not used here.
public final class ResponsesProvider: LLMProvider, @unchecked Sendable {
    private let baseURL: URL
    private let headers: [String: String]
    private let transport: HTTPTransport
    private let reasoning: ReasoningEffort

    public convenience init(baseURL: String, apiKey: String, headers: [String: String] = [:], reasoning: ReasoningEffort = .automatic) throws {
        try self.init(baseURL: baseURL, apiKey: apiKey, headers: headers, transport: HTTPTransport(), reasoning: reasoning)
    }

    init(baseURL: String, apiKey: String, headers: [String: String] = [:], transport: HTTPTransport, reasoning: ReasoningEffort = .automatic) throws {
        self.reasoning = reasoning
        self.baseURL = try HTTPTransport.baseURL(baseURL)
        try HTTPTransport.validateHeaders(["Authorization": apiKey])
        try HTTPTransport.validateHeaders(headers)
        var requestHeaders = headers
        for key in headers.keys where ["authorization", "content-type", "accept"].contains(key.lowercased()) {
            requestHeaders.removeValue(forKey: key)
        }
        if !apiKey.isEmpty { requestHeaders["Authorization"] = "Bearer \(apiKey)" }
        requestHeaders["Content-Type"] = "application/json"
        self.headers = requestHeaders
        self.transport = transport
    }

    deinit { transport.cancel() }

    public func cancel() async { transport.cancel() }

    public func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error> {
        let operation = transport.begin()
        let request: URLRequest
        do {
            request = self.request(path: "responses",
                body: try ChatGPTProvider.requestBody(messages: messages, model: model, tools: tools, reasoning: reasoning, namespacedTools: false))
        } catch {
            transport.finish(operation)
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let transport = transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { transport.finish(operation) }
                do {
                    let bytes = try await HTTPTransport.bytes(for: request, operation: operation)
                    defer { bytes.task.cancel() }
                    var parser = SSEParser()
                    var decoder = ChatGPTProvider.StreamDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let event = try parser.consume(byte) else { continue }
                        for output in try decoder.consume(event.data) { continuation.yield(output) }
                        if decoder.isFinished { break }
                    }
                    try Task.checkCancellation()
                    try parser.finish()
                    try decoder.finish()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            operation.installCancellation { task.cancel() }
            continuation.onTermination = { @Sendable _ in operation.cancel() }
        }
    }

    /// Routes come from the Console config; this path only exists for direct use.
    public func listModels() async throws -> [String] {
        throw ProviderError.unsupported("Model lists come from the OpenCode Console configuration.")
    }

    func request(path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
}
