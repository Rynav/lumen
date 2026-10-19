import Foundation

/// ChatGPT plan OAuth uses the public Responses API, never chat/completions or backend-api.
public final class ChatGPTProvider: LLMProvider, @unchecked Sendable {
    private let token: @Sendable () async throws -> String
    private let transport: HTTPTransport
    private let reasoning: ReasoningEffort

    public init(profileID: UUID, reasoning: ReasoningEffort = .automatic) {
        self.reasoning = reasoning
        token = { try await ChatGPTAuthorization.shared.accessToken(profileID: profileID) }
        transport = HTTPTransport()
    }

    init(token: @escaping @Sendable () async throws -> String, transport: HTTPTransport, reasoning: ReasoningEffort = .automatic) {
        self.reasoning = reasoning
        self.token = token; self.transport = transport
    }

    public func cancel() async { transport.cancel() }

    public func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error> {
        let operation = transport.begin()
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { transport.finish(operation) }
                do {
                    let token = try await token()
                    try Task.checkCancellation()
                    let request = try Self.request(path: "responses", token: token,
                        body: Self.requestBody(messages: messages, model: model, tools: tools, reasoning: reasoning))
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
                } catch { continuation.finish(throwing: error) }
            }
            operation.installCancellation { task.cancel() }
            continuation.onTermination = { @Sendable _ in operation.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        let operation = transport.begin()
        defer { transport.finish(operation) }
        let token = try await token()
        let bytes = try await HTTPTransport.bytes(for: Self.request(path: "models", token: token), operation: operation)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= 2_097_152 else { throw ProviderError.malformedStream }
        }
        return try Self.parseModels(data)
    }

    static func request(path: String, token: String, body: Data? = nil) throws -> URLRequest {
        try HTTPTransport.validateHeaders(["Authorization": token])
        guard let url = URL(string: "https://api.openai.com/v1/" + path) else { throw ProviderError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(body == nil ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    static func parseModels(_ data: Data) throws -> [String] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let models = value["models"]?.array else { throw ProviderError.malformedStream }
        var seen: Set<String> = []
        return models.compactMap { model in
            guard model["visibility"]?.string == "list", let slug = model["slug"]?.string,
                  seen.insert(slug).inserted else { return nil }
            return slug
        }
    }

    static func requestBody(messages: [Message], model: String, tools: [ToolDefinition], reasoning: ReasoningEffort = .automatic) throws -> Data {
        var input: [JSONValue] = []
        var instructions: [String] = []
        for message in messages {
            if message.role == .system { instructions.append(message.text); continue }
            var content: [JSONValue] = []
            var images: [JSONValue] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    if !text.isEmpty { content.append(.object(["type": .string("input_text"), "text": .string(text)])) }
                case .image(let image):
                    images.append(.object(["type": .string("input_image"), "image_url": .string(image.dataURL)]))
                case .reasoningSummary: break // Display only; replay the original opaque reasoning item instead.
                case .toolCall(let call):
                    input.append(.object(["type": .string("function_call"), "call_id": .string(call.id),
                        "name": .string(call.name), "namespace": .string("workspace"), "arguments": .string(call.arguments)]))
                case .toolResult(let result):
                    input.append(.object(["type": .string("function_call_output"), "call_id": .string(result.callID), "output": .string(result.content)]))
                case .providerItem(let item): input.append(item)
                }
            }
            if !content.isEmpty || !images.isEmpty {
                // Plain text keeps the flat string form; images require the content array.
                let encodedContent: JSONValue = images.isEmpty
                    ? .string(message.text) : .array(content + images)
                input.append(.object(["role": .string(message.role.rawValue), "content": encodedContent]))
            }
        }
        var body: [String: JSONValue] = ["model": .string(model), "input": .array(input), "stream": .bool(true),
            "store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])]
        if !instructions.isEmpty { body["instructions"] = .string(instructions.joined(separator: "\n")) }
        var reasoningOptions: [String: JSONValue] = [:]
        if reasoning != .automatic { reasoningOptions["effort"] = .string(reasoning.rawValue) }
        // ponytail: known summary-capable families; use catalog capabilities if reliable metadata becomes available.
        if ["gpt-5", "gpt-6", "o3", "o4", "codex-"].contains(where: model.lowercased().hasPrefix) {
            reasoningOptions["summary"] = .string("auto")
        }
        if !reasoningOptions.isEmpty { body["reasoning"] = .object(reasoningOptions) }
        if !tools.isEmpty {
            body["tools"] = .array([.object(["type": .string("namespace"), "name": .string("workspace"),
                "description": .string("Project inspection and user-approved edits"), "tools": .array(tools.map {
                    .object(["type": .string("function"), "name": .string($0.name), "description": .string($0.description),
                             "parameters": $0.parameters, "strict": .bool(false)])
                })])])
        }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    struct StreamDecoder {
        private(set) var isFinished = false
        private var summaries: [String: String] = [:]
        mutating func consume(_ data: String) throws -> [StreamEvent] {
            guard !isFinished else { throw ProviderError.malformedStream }
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
            guard let type = event["type"]?.string else { throw ProviderError.malformedStream }
            switch type {
            case "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
                 "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
                guard let itemID = event["item_id"]?.string, !itemID.isEmpty,
                      let index = event["summary_index"]?.number.flatMap(Int.init(exactly:)), index >= 0 else {
                    throw ProviderError.malformedStream
                }
                let id = "\(itemID):\(index)"
                let text: String
                if type == "response.reasoning_summary_text.delta" {
                    guard let delta = event["delta"]?.string else { throw ProviderError.malformedStream }
                    text = (summaries[id] ?? "") + delta
                } else if type == "response.reasoning_summary_text.done" {
                    guard let completed = event["text"]?.string else { throw ProviderError.malformedStream }
                    text = completed
                } else {
                    guard event["part"]?["type"]?.string == "summary_text", let part = event["part"]?["text"]?.string else {
                        throw ProviderError.malformedStream
                    }
                    text = type.hasSuffix(".added") ? summaries[id] ?? part : part
                }
                summaries[id] = text
                return [.reasoningSummary(id: id, text: text)]
            case "response.output_item.added":
                guard event["item"]?["type"]?.string == "reasoning", let id = event["item"]?["id"]?.string else { return [] }
                return [.reasoningSummary(id: id + ":0", text: "")]
            case "response.output_text.delta":
                guard let delta = event["delta"]?.string else { throw ProviderError.malformedStream }
                return [.text(delta)]
            case "response.output_item.done":
                guard let item = event["item"] else { throw ProviderError.malformedStream }
                if item["type"]?.string == "reasoning" {
                    var output: [StreamEvent] = []
                    if let itemID = item["id"]?.string {
                        for (index, part) in (item["summary"]?.array ?? []).enumerated() {
                            guard part["type"]?.string == "summary_text", let text = part["text"]?.string else { continue }
                            let id = "\(itemID):\(index)"
                            summaries[id] = text
                            output.append(.reasoningSummary(id: id, text: text))
                        }
                    }
                    return output + [.providerItem(item)]
                }
                guard item["type"]?.string == "function_call" else { return [] }
                guard let id = item["call_id"]?.string, !id.isEmpty,
                      let name = item["name"]?.string, !name.isEmpty,
                      item["namespace"] == nil || item["namespace"]?.string == "workspace",
                      let arguments = item["arguments"]?.string,
                      (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)).object) != nil else {
                    throw ProviderError.malformedStream
                }
                return [.toolCall(ToolCall(id: id, name: name, arguments: arguments))]
            case "response.completed":
                guard event["response"]?["status"]?.string == "completed" else { throw ProviderError.incompleteStream }
                isFinished = true
                var output: [StreamEvent] = []
                if let usage = event["response"]?["usage"] {
                    guard let input = usage["input_tokens"]?.number.flatMap(Int.init(exactly:)), input >= 0,
                          let tokens = usage["output_tokens"]?.number.flatMap(Int.init(exactly:)), tokens >= 0 else {
                        throw ProviderError.malformedStream
                    }
                    output.append(.usage(TokenUsage(inputTokens: input, outputTokens: tokens)))
                }
                return output + [.finished]
            case "response.failed", "error":
                let code = event["response"]?["error"]?["code"]?.string ?? event["code"]?.string
                if ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"].contains(code) {
                    throw ProviderError.unsupported("ChatGPT plan usage is unavailable or its limit was reached. Review app access and limits in ChatGPT Settings → Usage.")
                }
                if code == "context_length_exceeded" { throw ProviderError.contextLength }
                throw ProviderError.unsupported("The ChatGPT response failed. Check account access or try again.")
            case "response.incomplete": throw ProviderError.incompleteStream
            default: return []
            }
        }

        func finish() throws { guard isFinished else { throw ProviderError.incompleteStream } }
    }
}
