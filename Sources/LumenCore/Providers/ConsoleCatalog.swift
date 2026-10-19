import Foundation

/// The API family that serves a model. OpenCode Console publishes one family per
/// model and rejects the model on another family's path, so this is not optional.
enum ConsoleEndpoint: String, Sendable {
    case chat, responses, messages, google
}

/// One model's route: the family and that family's base URL, plus what a picker
/// shows for it.
struct ConsoleModel: Equatable, Sendable {
    var endpoint: ConsoleEndpoint
    var baseURL: String
    var name: String?
    var isFree: Bool
}

/// The workspace's gateway routes and headers from `GET /api/v2/config`.
/// `settings.apiKey` values are templates naming the caller's own key, so they
/// are never read or stored.
struct ConsoleCatalog: Equatable, Sendable {
    var models: [String: ConsoleModel] = [:]
    var headers: [String: String] = [:]

    static func fetch(server: String, apiKey: String, headers: [String: String] = [:], transport: HTTPTransport) async throws -> ConsoleCatalog {
        let base = try HTTPTransport.baseURL(server)
        try HTTPTransport.validateHeaders(["Authorization": apiKey])
        try HTTPTransport.validateHeaders(headers)
        var request = URLRequest(url: base.appendingPathComponent("api/v2/config"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let operation = transport.begin()
        defer { transport.finish(operation) }
        let bytes = try await HTTPTransport.bytes(for: request, operation: operation)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= 4_194_304 else { throw ProviderError.malformedStream }
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ConsoleCatalog {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let providers = value["providers"]?.object else {
            throw ProviderError.unsupported("OpenCode Console returned no providers. Check the server URL and this key's permissions.")
        }
        var catalog = ConsoleCatalog()
        for provider in providers.values {
            guard let provider = provider.object else { continue }
            // shortcut: provider headers merge into one set; they all target the same host.
            for (name, value) in provider["headers"]?.object ?? [:] {
                if let value = value.string { catalog.headers[name] = value }
            }
            let providerBase = provider["settings"]?["baseURL"]?.string
            for (id, entry) in provider["models"]?.object ?? [:] {
                guard let entry = entry.object, entry["disabled"] != .bool(true) else { continue }
                let endpoint = endpoint(for: entry["package"]?.string ?? provider["package"]?.string)
                guard let base = entry["settings"]?["baseURL"]?.string ?? providerBase else { continue }
                catalog.models[id] = ConsoleModel(endpoint: endpoint, baseURL: familyBase(base, endpoint: endpoint),
                                                  name: entry["name"]?.string, isFree: isFree(entry))
            }
        }
        return catalog
    }

    /// Console publishes one cost entry per model (a tier array); every tier at
    /// zero means the workspace is not charged for it.
    static func isFree(_ entry: [String: JSONValue]) -> Bool {
        let tiers = entry["cost"]?.array ?? entry["cost"].map { [$0] } ?? []
        guard !tiers.isEmpty else { return false }
        return tiers.allSatisfy { ($0["input"]?.number ?? 1) == 0 && ($0["output"]?.number ?? 1) == 0 }
    }

    static func endpoint(for package: String?) -> ConsoleEndpoint {
        let name = (package ?? "").lowercased()
        if name.contains("anthropic") { return .messages }
        if name.contains("google") { return .google }
        if name.contains("openai-compatible") { return .chat }
        if name.contains("openai") { return .responses }
        return .chat
    }

    /// Console serves each family under its own path segment
    /// (`/inference/openai/v1`, `/inference/anthropic/v1`). A model whose package
    /// differs from its provider's uses that family's segment.
    static func familyBase(_ baseURL: String, endpoint: ConsoleEndpoint) -> String {
        guard endpoint != .google, var components = URLComponents(string: baseURL) else { return baseURL }
        let target = endpoint == .messages ? "anthropic" : "openai"
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let index = segments.firstIndex(where: { ["openai", "anthropic"].contains($0) }),
              segments[index] != target else { return baseURL }
        segments[index] = target
        components.path = segments.joined(separator: "/")
        return components.string ?? baseURL
    }
}
