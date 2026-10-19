import Foundation

/// Anthropic Messages API over SSE. Extended thinking is not requested: it would
/// require round-tripping signed thinking blocks, which this app never stores.
public final class AnthropicProvider: LLMProvider, @unchecked Sendable {
    private let baseURL: URL
    private let headers: [String: String]
    private let transport: HTTPTransport

    public convenience init(profile: ProviderProfile, apiKey: String, headers: [String: String] = [:]) throws {
        try self.init(profile: profile, apiKey: apiKey, headers: headers, transport: HTTPTransport())
    }

    init(profile: ProviderProfile, apiKey: String, headers: [String: String] = [:], transport: HTTPTransport) throws {
        baseURL = try HTTPTransport.baseURL(profile.baseURL)
        try HTTPTransport.validateHeaders(["x-api-key": apiKey])
        try HTTPTransport.validateHeaders(headers)
        var requestHeaders = headers
        let reserved = ["x-api-key", "anthropic-version", "content-type", "accept"]
        for key in headers.keys where reserved.contains(key.lowercased()) {
            requestHeaders.removeValue(forKey: key)
        }
        if !apiKey.isEmpty { requestHeaders["x-api-key"] = apiKey }
        requestHeaders["anthropic-version"] = "2023-06-01"
        requestHeaders["Content-Type"] = "application/json"
        self.headers = requestHeaders
        self.transport = transport
    }

    deinit { transport.cancel() }

    public func cancel() async { transport.cancel() }

    /// Accepts a base URL with or without a trailing `/v1`.
    private static func endpoint(_ base: URL, _ path: String) -> URL {
        var base = base
        if base.lastPathComponent == "v1" { base.deleteLastPathComponent() }
        return base.appendingPathComponent(path)
    }

    func request(path: String, query: String? = nil, body: Data? = nil) -> URLRequest {
        var url = Self.endpoint(baseURL, path)
        if let query, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = query
            if let withQuery = components.url { url = withQuery }
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(body == nil ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    public func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error> {
        let operation = transport.begin()
        let transport = transport
        let request: URLRequest
        do {
            request = self.request(path: "v1/messages", body: try Self.requestBody(messages: messages, model: model, tools: tools))
        } catch {
            transport.finish(operation)
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { transport.finish(operation) }
                do {
                    let bytes = try await HTTPTransport.bytes(for: request, operation: operation)
                    defer { bytes.task.cancel() }
                    var parser = SSEParser()
                    var decoder = StreamDecoder()
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
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            operation.installCancellation { task.cancel() }
            continuation.onTermination = { @Sendable _ in operation.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        let operation = transport.begin()
        let transport = transport
        let request = request(path: "v1/models", query: "limit=1000")
        let task = Task {
            defer { transport.finish(operation) }
            let bytes = try await HTTPTransport.bytes(for: request, operation: operation)
            defer { bytes.task.cancel() }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                guard data.count <= 2_097_152 else { throw ProviderError.malformedStream }
            }
            try Task.checkCancellation()
            return try Self.parseModels(data)
        }
        operation.installCancellation { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            operation.cancel()
        }
    }

    static func parseModels(_ data: Data) throws -> [String] {
        struct Models: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        guard let models = try? JSONDecoder().decode(Models.self, from: data) else {
            throw ProviderError.malformedStream
        }
        // Anthropic paginates with has_more/last_id; one wide page is enough for the picker.
        return Array(Set(models.data.map(\.id))).sorted()
    }

    static let maxTokens = 8192

    static func requestBody(messages: [Message], model: String, tools: [ToolDefinition]) throws -> Data {
        var system = ""
        var encoded: [JSONValue] = []
        var pendingResults: [JSONValue] = []

        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            encoded.append(.object(["role": .string("user"), "content": .array(pendingResults)]))
            pendingResults.removeAll()
        }
        func toolResultBlock(_ result: ToolResult) -> JSONValue {
            .object([
                "type": .string("tool_result"), "tool_use_id": .string(result.callID),
                "content": .string(result.content), "is_error": .bool(result.isError)
            ])
        }

        for message in messages {
            switch message.role {
            case .system:
                if !message.text.isEmpty {
                    system += (system.isEmpty ? "" : "\n\n") + message.text
                }
            case .tool:
                // Consecutive tool results must share one user message.
                for part in message.parts { if case .toolResult(let result) = part { pendingResults.append(toolResultBlock(result)) } }
            case .user, .assistant:
                flushResults()
                var blocks: [JSONValue] = []
                for part in message.parts {
                    switch part {
                    case .text(let text):
                        if !text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
                    case .image(let image):
                        blocks.append(.object([
                            "type": .string("image"),
                            "source": .object([
                                "type": .string("base64"), "media_type": .string(image.mediaType),
                                "data": .string(image.data.base64EncodedString())
                            ])
                        ]))
                    case .toolCall(let call):
                        let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .object([:])
                        blocks.append(.object([
                            "type": .string("tool_use"), "id": .string(call.id),
                            "name": .string(call.name), "input": input
                        ]))
                    case .toolResult(let result):
                        blocks.append(toolResultBlock(result))
                    case .reasoningSummary, .providerItem:
                        break
                    }
                }
                if !blocks.isEmpty { encoded.append(.object(["role": .string(message.role.rawValue), "content": .array(blocks)])) }
            }
        }
        flushResults()

        var body: [String: JSONValue] = [
            "model": .string(model), "max_tokens": .number(Double(maxTokens)),
            "messages": .array(encoded), "stream": .bool(true)
        ]
        if !system.isEmpty { body["system"] = .string(system) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object(["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.parameters])
            })
        }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    struct StreamDecoder {
        private struct Event: Decodable {
            struct Block: Decodable { var type: String?; var id: String?; var name: String? }
            struct Delta: Decodable { var type: String?; var text: String?; var partial_json: String?; var thinking: String? }
            struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
            struct Message: Decodable { var usage: Usage? }
            var type: String
            var index: Int?
            var content_block: Block?
            var delta: Delta?
            var usage: Usage?
            var message: Message?
            var error: JSONValue?
        }

        private struct PendingTool { var id: String; var name: String; var json: String }
        private var tools: [Int: PendingTool] = [:]
        private var reasoning: [Int: String] = [:]
        private var inputTokens = 0
        private var outputTokens = 0
        private var stopped = false
        private(set) var isFinished = false

        mutating func consume(_ data: String) throws -> [StreamEvent] {
            guard !isFinished else { throw ProviderError.malformedStream }
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(data.utf8)) else {
                throw ProviderError.malformedStream
            }
            if event.error != nil { throw HTTPTransport.responseError(status: 400, body: Data(data.utf8)) }
            switch event.type {
            case "message_start":
                inputTokens = event.message?.usage?.input_tokens ?? 0
                return []
            case "content_block_start":
                guard let index = event.index, let block = event.content_block else { throw ProviderError.malformedStream }
                if block.type == "tool_use" {
                    guard let id = block.id, let name = block.name, !name.isEmpty else { throw ProviderError.malformedStream }
                    tools[index] = PendingTool(id: id, name: name, json: "")
                }
                return []
            case "content_block_delta":
                guard let index = event.index, let delta = event.delta else { throw ProviderError.malformedStream }
                switch delta.type {
                case "text_delta":
                    guard let text = delta.text else { throw ProviderError.malformedStream }
                    return text.isEmpty ? [] : [.text(text)]
                case "input_json_delta":
                    guard let partial = delta.partial_json, tools[index] != nil else { throw ProviderError.malformedStream }
                    tools[index]?.json += partial
                    return []
                case "thinking_delta":
                    guard let thinking = delta.thinking else { throw ProviderError.malformedStream }
                    let text = (reasoning[index] ?? "") + thinking
                    reasoning[index] = text
                    return text.isEmpty ? [] : [.reasoningSummary(id: "anthropic:\(index)", text: text)]
                default:
                    return []
                }
            case "content_block_stop":
                guard let index = event.index else { throw ProviderError.malformedStream }
                reasoning[index] = nil
                guard let pending = tools[index] else { return [] }
                tools[index] = nil
                guard let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(pending.json.utf8)),
                      arguments.object != nil else { throw ProviderError.malformedStream }
                return [.toolCall(ToolCall(id: pending.id, name: pending.name, arguments: pending.json))]
            case "message_delta":
                outputTokens = event.usage?.output_tokens ?? outputTokens
                guard inputTokens >= 0, outputTokens >= 0 else { throw ProviderError.malformedStream }
                return [.usage(TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))]
            case "message_stop":
                stopped = true
                isFinished = true
                return [.finished]
            case "error":
                throw HTTPTransport.responseError(status: 400, body: Data(data.utf8))
            default:
                return []
            }
        }

        func finish() throws {
            guard stopped, tools.isEmpty else { throw ProviderError.incompleteStream }
        }
    }
}
