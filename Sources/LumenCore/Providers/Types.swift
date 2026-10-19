import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case automatic, none, minimal, low, medium, high, xhigh
    public var title: String { self == .automatic ? "Default" : self == .xhigh ? "Extra high" : rawValue.capitalized }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public subscript(key: String) -> JSONValue? { object?[key] }
}

public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var callID: String
    public var content: String
    public var isError: Bool
    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID; self.content = content; self.isError = isError
    }
    /// Returned when a tool call arrives on the final permitted request, where no
    /// tools are advertised.
    public static let toolsDisabled = "Tools are disabled: this task reached its maximum number of steps. Nothing was run. Reply with text only; the user must send a new message to continue."
}

public enum ContentPart: Codable, Equatable, Sendable {
    case text(String)
    case reasoningSummary(id: String, text: String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case providerItem(JSONValue)
    case image(ImageAttachment)
}

/// An inline image sent to the model. `data` is the raw encoded bytes (typically
/// PNG) carried across providers and persisted with the conversation; `mediaType`
/// is an IANA type such as `image/png` used to build data URLs and provider blocks.
public struct ImageAttachment: Codable, Equatable, Sendable {
    public var mediaType: String
    public var data: Data
    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
    /// The `data:<mediaType>;base64,<payload>` URL both OpenAI and the Responses API accept.
    public var dataURL: String {
        "data:\(mediaType);base64,\(data.base64EncodedString())"
    }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var id: UUID
    public var role: Role
    public var parts: [ContentPart]
    public init(id: UUID = UUID(), role: Role, parts: [ContentPart]) {
        self.id = id; self.role = role; self.parts = parts
    }
    public init(role: Role, text: String) { self.init(role: role, parts: [.text(text)]) }
    public var text: String {
        parts.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
    }
    public var reasoningSummary: String {
        parts.compactMap { part -> String? in
            guard case .reasoningSummary(_, let text) = part, !text.isEmpty else { return nil }
            return text
        }.joined(separator: "\n\n")
    }
    public var images: [ImageAttachment] {
        parts.compactMap { if case .image(let image) = $0 { return image }; return nil }
    }
    public var hasReasoning: Bool {
        parts.contains {
            if case .reasoningSummary = $0 { return true }
            if case .providerItem(let item) = $0 { return item["type"]?.string == "reasoning" }
            return false
        }
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
    public func estimatedCost(inputPerMillion: Double?, outputPerMillion: Double?) -> Double? {
        guard let inputPerMillion, let outputPerMillion,
              inputPerMillion.isFinite, outputPerMillion.isFinite,
              inputPerMillion >= 0, outputPerMillion >= 0,
              inputTokens >= 0, outputTokens >= 0 else { return nil }
        return (Double(inputTokens) * inputPerMillion + Double(outputTokens) * outputPerMillion) / 1_000_000
    }
}

/// Streaming throughput of one response, shown beside the token counts in the composer.
public enum TokenRate {
    /// Output tokens per second, or nil when there is nothing meaningful to report:
    /// no generated tokens, no elapsed time, or a non-finite duration.
    public static func tokensPerSecond(outputTokens: Int, seconds: Double) -> Double? {
        guard outputTokens > 0, seconds.isFinite, seconds > 0 else { return nil }
        return Double(outputTokens) / seconds
    }

    /// Converts a monotonic clock duration into seconds for the rate above.
    public static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

public enum StreamEvent: Sendable, Equatable {
    case text(String)
    case reasoningSummary(id: String, text: String)
    case toolCall(ToolCall)
    case providerItem(JSONValue)
    case usage(TokenUsage)
    case finished
}

public struct ToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

/// What a model picker needs: the id sent to the provider, the provider's own
/// display name when it publishes one, and whether it costs nothing.
public struct ModelInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var isFree: Bool
    public init(id: String, name: String? = nil, isFree: Bool = false) {
        self.id = id; self.name = name; self.isFree = isFree
    }
    public var label: String {
        if let name, !name.isEmpty { return name }
        return id
    }
}

public protocol LLMProvider: Sendable {
    func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error>
    func listModels() async throws -> [String]
    func cancel() async
}

public extension LLMProvider {
    /// Providers with a richer catalog than bare ids override this.
    func modelInfo() async throws -> [ModelInfo] {
        try await listModels().map { ModelInfo(id: $0) }
    }
}
