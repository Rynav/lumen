import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    /// The base prompt used when the user has not written their own. It carries the
    /// `${LUMEN_TOOL_GUIDANCE}` placeholder that `SystemPrompt.render` fills with
    /// guidance for the tools actually advertised in a request.
    public static var defaultSystemPrompt: String { SystemPrompt.base }

    /// Recognized as "user never edited this" so the current default replaces it.
    /// Values the user actually wrote are never overwritten.
    public static let legacySystemPrompts: [String] = [
        SystemPrompt.legacyDefault,
        "You are a helpful coding agent. Inspect the workspace before changing files.",
    ]
    public var profiles: [ProviderProfile] = []
    public var selectedProfileID: UUID?
    public var models: [UUID: String] = [:]
    public var systemPrompt = Self.defaultSystemPrompt
    public var maxIterations = 100
    public var reasoning = ReasoningEffort.automatic
    public var approvalPolicy = ApprovalPolicy.reviewEverything
    public var mcpServers: [MCPServerConfig] = []
    public var workspacePath: String?
    public var projectPaths: [String]?
    public var selectedConversationID: UUID?
    public init() {}

    /// Lenient decoding: fields added in later versions fall back to their defaults
    /// instead of failing the whole load, so an older `config.json` (or a legacy
    /// `settings.json` from a previous schema) still restores. A file that is not
    /// valid JSON at all still throws, so genuine damage is reported, not overwritten.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? container.decodeIfPresent([ProviderProfile].self, forKey: .profiles)) ?? []
        selectedProfileID = try? container.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        models = (try? container.decodeIfPresent([UUID: String].self, forKey: .models)) ?? [:]
        systemPrompt = (try? container.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? Self.defaultSystemPrompt
        maxIterations = (try? container.decodeIfPresent(Int.self, forKey: .maxIterations)) ?? 100
        reasoning = (try? container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoning)) ?? .automatic
        approvalPolicy = (try? container.decodeIfPresent(ApprovalPolicy.self, forKey: .approvalPolicy)) ?? .reviewEverything
        mcpServers = (try? container.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers)) ?? []
        workspacePath = try? container.decodeIfPresent(String.self, forKey: .workspacePath)
        projectPaths = try? container.decodeIfPresent([String].self, forKey: .projectPaths)
        selectedConversationID = try? container.decodeIfPresent(UUID.self, forKey: .selectedConversationID)
    }
}

/// Non-secret configuration only. Credentials remain in Keychain.
public struct ConfigurationStore: Sendable {
    public let directory: URL
    public let filename: String
    public init(directory: URL = ConfigurationStore.defaultDirectory, filename: String = "config.json") {
        self.directory = directory
        self.filename = filename
    }
    /// App-owned state lives in the home directory so the config is easy to find and hand-edit.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumen", isDirectory: true)
    }
    /// Where pre-migration builds stored the configuration; read once, never written.
    static var legacyURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Lumen/settings.json")
    }
    public func load() throws -> AppConfiguration {
        if let data = try WorkspaceService.loadConfiguration(in: directory, filename: filename) {
            // A damaged primary file is reported, not silently replaced with defaults.
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        }
        // Best-effort one-time migration from the legacy location: never block writing
        // the new file, even if the old one is unreadable.
        if directory == Self.defaultDirectory, let data = try? Data(contentsOf: Self.legacyURL) {
            return (try? JSONDecoder().decode(AppConfiguration.self, from: data)) ?? AppConfiguration()
        }
        return AppConfiguration()
    }
    public func save(_ configuration: AppConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try WorkspaceService.saveConfiguration(encoder.encode(configuration), in: directory, filename: filename)
    }
}
