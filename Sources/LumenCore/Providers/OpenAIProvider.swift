import Foundation

public final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    private let baseURL: URL
    private let headers: [String: String]
    private let transport: HTTPTransport
    private let reasoning: ReasoningEffort

    public convenience init(profile: ProviderProfile, apiKey: String, headers: [String: String] = [:], reasoning: ReasoningEffort = .automatic) throws {
        try self.init(profile: profile, apiKey: apiKey, headers: headers, transport: HTTPTransport(), reasoning: reasoning)
    }

    init(profile: ProviderProfile, apiKey: String, headers: [String: String] = [:], transport: HTTPTransport, reasoning: ReasoningEffort = .automatic) throws {
        self.reasoning = reasoning
        baseURL = try HTTPTransport.baseURL(profile.baseURL)
        try HTTPTransport.validateHeaders(["Authorization": apiKey])
        try HTTPTransport.validateHeaders(headers)
        var requestHeaders = headers
        // Header names are case insensitive; custom headers cannot shadow auth.
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

    func request(path: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
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
            request = self.request(path: "chat/completions", body: try Self.requestBody(messages: messages, model: model, tools: tools, reasoning: reasoning))
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
        let request = request(path: "models")
        let task = Task {
            defer { transport.finish(operation) }
            let bytes = try await HTTPTransport.bytes(for: request, operation: operation)
            defer { bytes.task.cancel() }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
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
        return Array(Set(models.data.map(\.id))).sorted()
    }

    static func requestBody(messages: [Message], model: String, tools: [ToolDefinition], reasoning: ReasoningEffort = .automatic) throws -> Data {
        var encodedMessages: [JSONValue] = []
        for message in messages {
            var calls: [JSONValue] = []
            var results: [JSONValue] = []
            var content: [JSONValue] = []
            var images: [JSONValue] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
                case .reasoningSummary, .providerItem: break
                case .image(let image):
                    images.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string(image.dataURL)])]))
                case .toolCall(let call):
                    calls.append(.object([
                        "id": .string(call.id), "type": .string("function"),
                        "function": .object(["name": .string(call.name), "arguments": .string(call.arguments)])
                    ]))
                case .toolResult(let result):
                    results.append(.object([
                        "role": .string("tool"), "tool_call_id": .string(result.callID), "content": .string(result.content)
                    ]))
                }
            }
            if !content.isEmpty || !images.isEmpty || !calls.isEmpty || (results.isEmpty && message.role != .assistant) {
                // Images require the multi-part content array; plain text keeps the simpler string form.
                let encodedContent: JSONValue = images.isEmpty
                    ? .string(message.text) : .array(content + images)
                var value: [String: JSONValue] = ["role": .string(message.role.rawValue), "content": encodedContent]
                if !calls.isEmpty { value["tool_calls"] = .array(calls) }
                encodedMessages.append(.object(value))
            }
            encodedMessages.append(contentsOf: results)
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "messages": .array(encodedMessages), "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)])
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object(["type": .string("function"), "function": .object([
                    "name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters
                ])])
            })
        }
        if reasoning != .automatic { body["reasoning_effort"] = .string(reasoning.rawValue) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    struct StreamDecoder {
        private struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    struct Call: Decodable {
                        struct Function: Decodable { var name: String?; var arguments: String? }
                        var index: Int
                        var id: String?
                        var function: Function?
                    }
                    var content: String?
                    var reasoning_content: JSONValue?
                    var reasoning: JSONValue?
                    var tool_calls: [Call]?
                }
                var index: Int
                var delta: Delta?
                var finish_reason: String?
            }
            struct Usage: Decodable { var prompt_tokens: Int; var completion_tokens: Int }
            var choices: [Choice]?
            var usage: Usage?
            var error: JSONValue?
        }

        private var calls: [Int: ToolCall] = [:]
        private var choiceFinished = false
        private var reasoningText = ""
        private(set) var isFinished = false

        mutating func consume(_ data: String) throws -> [StreamEvent] {
            guard !isFinished else { throw ProviderError.malformedStream }
            if data == "[DONE]" {
                guard choiceFinished else { throw ProviderError.incompleteStream }
                isFinished = true
                return [.finished]
            }
            let bytes = Data(data.utf8)
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: bytes) else {
                throw ProviderError.malformedStream
            }
            if chunk.error != nil { throw HTTPTransport.responseError(status: 400, body: bytes) }
            guard chunk.choices != nil || chunk.usage != nil else { throw ProviderError.malformedStream }
            var events: [StreamEvent] = []
            for choice in chunk.choices ?? [] where choice.index == 0 {
                // OpenRouter repeats finish_reason on the trailing usage chunk; ignore post-finish choices.
                guard !choiceFinished else { continue }
                if let reasoning = choice.delta?.reasoning_content?.string ?? choice.delta?.reasoning?.string, !reasoning.isEmpty {
                    reasoningText += reasoning
                    events.append(.reasoningSummary(id: "compatible:0", text: reasoningText))
                }
                if let text = choice.delta?.content, !text.isEmpty { events.append(.text(text)) }
                for delta in choice.delta?.tool_calls ?? [] {
                    guard delta.index >= 0 else { throw ProviderError.malformedStream }
                    var call = calls[delta.index] ?? ToolCall(id: "", name: "", arguments: "")
                    call.id += delta.id ?? ""
                    call.name += delta.function?.name ?? ""
                    call.arguments += delta.function?.arguments ?? ""
                    calls[delta.index] = call
                }
                if let reason = choice.finish_reason {
                    if !calls.isEmpty, reason != "tool_calls", reason != "stop" {
                        throw ProviderError.incompleteStream
                    }
                    for index in calls.keys.sorted() {
                        guard let call = calls[index], !call.id.isEmpty, !call.name.isEmpty,
                              let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)),
                              arguments.object != nil else { throw ProviderError.malformedStream }
                        events.append(.toolCall(call))
                    }
                    calls.removeAll()
                    choiceFinished = true
                }
            }
            if let usage = chunk.usage {
                guard usage.prompt_tokens >= 0, usage.completion_tokens >= 0 else { throw ProviderError.malformedStream }
                events.append(.usage(TokenUsage(inputTokens: usage.prompt_tokens, outputTokens: usage.completion_tokens)))
            }
            return events
        }

        func finish() throws {
            guard isFinished else { throw ProviderError.incompleteStream }
        }
    }
}
