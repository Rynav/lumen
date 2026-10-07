import Foundation

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
}

public enum ContentPart: Codable, Equatable, Sendable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
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
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
    public func estimatedCost(inputPerMillion: Double?, outputPerMillion: Double?) -> Double? {
        guard let inputPerMillion, let outputPerMillion else { return nil }
        return (Double(inputTokens) * inputPerMillion + Double(outputTokens) * outputPerMillion) / 1_000_000
    }
}

public enum StreamEvent: Sendable, Equatable {
    case text(String)
    case toolCall(ToolCall)
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

public protocol LLMProvider: Sendable {
    func stream(messages: [Message], model: String, tools: [ToolDefinition]) -> AsyncThrowingStream<StreamEvent, any Error>
    func listModels() async throws -> [String]
    func cancel() async
}
