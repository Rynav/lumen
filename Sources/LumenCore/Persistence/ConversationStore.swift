import Foundation

/// A standing summary of a conversation's older turns, and how many leading
/// messages it replaces. Saved with the conversation so a restart neither
/// re-summarizes nor re-sends what was already compressed.
public struct ConversationCompaction: Codable, Equatable, Sendable {
    public var summary: String
    public var covered: Int
    public init(summary: String, covered: Int) {
        self.summary = summary; self.covered = covered
    }
    /// The system note that stands in for the covered messages.
    var note: String { "Summary of earlier conversation (the full history stays visible in the app):\n\(summary)" }
}

/// Chat content only; commands and applied changes stay tied to the workspace session.
public struct ConversationSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectPath: String?
    public var messages: [Message]
    public var draft: String
    public var profileID: UUID?
    public var usage: TokenUsage?
    public var estimatedCost: Double?
    public var compaction: ConversationCompaction?
    public var savedAt: Date

    public init(id: UUID, projectPath: String?, messages: [Message], draft: String,
                profileID: UUID?, usage: TokenUsage?, estimatedCost: Double?,
                compaction: ConversationCompaction? = nil, savedAt: Date) {
        self.id = id; self.projectPath = projectPath; self.messages = messages; self.draft = draft
        self.profileID = profileID; self.usage = usage; self.estimatedCost = estimatedCost
        self.compaction = compaction; self.savedAt = savedAt
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
