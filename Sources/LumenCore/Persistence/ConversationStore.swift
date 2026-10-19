import Foundation

/// Chat content only; commands and applied changes stay tied to the workspace session.
public struct ConversationSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectPath: String?
    public var messages: [Message]
    public var draft: String
    public var profileID: UUID?
    public var usage: TokenUsage?
    public var estimatedCost: Double?
    public var savedAt: Date

    public init(id: UUID, projectPath: String?, messages: [Message], draft: String,
                profileID: UUID?, usage: TokenUsage?, estimatedCost: Double?, savedAt: Date) {
        self.id = id; self.projectPath = projectPath; self.messages = messages; self.draft = draft
        self.profileID = profileID; self.usage = usage; self.estimatedCost = estimatedCost; self.savedAt = savedAt
    }
}

/// Cross-launch conversation history. Damaged files fall back to an empty history.
public struct ConversationStore: Sendable {
    public let directory: URL
    public init(directory: URL = ConfigurationStore.defaultDirectory) {
        self.directory = directory
    }
    /// Where pre-migration builds stored conversation history; read once, never written.
    static var legacyURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Lumen/conversations.json")
    }
    public func load() -> [ConversationSnapshot] {
        if let data = try? WorkspaceService.loadAppFile(named: "conversations.json", in: directory),
           let snapshots = try? JSONDecoder().decode([ConversationSnapshot].self, from: data) {
            return snapshots
        }
        // Read history left by pre-migration builds once; only the default location migrates.
        guard directory == ConfigurationStore.defaultDirectory,
              let legacy = try? Data(contentsOf: Self.legacyURL),
              let snapshots = try? JSONDecoder().decode([ConversationSnapshot].self, from: legacy) else { return [] }
        return snapshots
    }
    public func save(_ snapshots: [ConversationSnapshot]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try WorkspaceService.saveAppFile(encoder.encode(snapshots), named: "conversations.json", in: directory)
    }
}
