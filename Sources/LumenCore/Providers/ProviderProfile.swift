import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAI
    case chatGPT
    case anthropic
    case openRouter
    case openCode
    case compatible
}

public struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var defaultModel: String
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String,
        defaultModel: String,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
    }
}
