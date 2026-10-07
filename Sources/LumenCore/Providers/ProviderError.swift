import Foundation

public enum ProviderError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unauthorized
    case rateLimited
    case contextLength
    case http(Int)
    case malformedStream
    case incompleteStream
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP(S) API base URL without embedded credentials or query parameters."
        case .unauthorized: "The provider rejected your credentials. Check the API key in Settings."
        case .rateLimited: "The provider is rate limiting requests. Wait a moment and try again."
        case .contextLength: "This conversation exceeds the model's context limit. Start a new conversation or choose a larger-context model."
        case .http(let status): "The provider returned HTTP \(status). Check the endpoint and model."
        case .malformedStream: "The provider sent a malformed stream. Partial output has been kept; try again."
        case .incompleteStream: "The connection ended before the response completed. Partial output has been kept."
        case .unsupported(let message): message
        }
    }
}
