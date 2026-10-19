import Foundation

public struct FileEditProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let before: String?
    public let after: String?
    /// Permission bits of the original file, kept so undoing a deletion restores them.
    public var mode: UInt16? = nil

    public var diff: [DiffLine] { DiffLine.compare(before ?? "", after ?? "") }
}

/// One approval containing several file edits. The user may apply a subset.
public struct EditBatchProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let edits: [FileEditProposal]

    public init(id: UUID = UUID(), edits: [FileEditProposal]) {
        self.id = id
        self.edits = edits
    }
}

public struct AppliedChange: Identifiable, Equatable, Sendable {
    public var id: UUID { proposal.id }
    public let proposal: FileEditProposal
    public let backupPath: String
    public var undone = false
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, removed, added }
    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public static func compare(_ before: String, _ after: String) -> [DiffLine] {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        var removed: Set<Int> = [], added: Set<Int> = []
        // ponytail: cap the quadratic diff worst case; large files get a complete replacement view.
        if old.count + new.count > 4_000 {
            removed = Set(old.indices); added = Set(new.indices)
        } else {
            for change in new.difference(from: old) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): added.insert(offset)
                }
            }
        }
        var rows: [DiffLine] = [], left = 0, right = 0
        while left < old.count || right < new.count {
            if left < old.count, removed.contains(left) {
                rows.append(DiffLine(id: rows.count, kind: .removed, oldNumber: left + 1, newNumber: nil, text: old[left])); left += 1
            } else if right < new.count, added.contains(right) {
                rows.append(DiffLine(id: rows.count, kind: .added, oldNumber: nil, newNumber: right + 1, text: new[right])); right += 1
            } else if left < old.count, right < new.count {
                rows.append(DiffLine(id: rows.count, kind: .context, oldNumber: left + 1, newNumber: right + 1, text: old[left]))
                left += 1; right += 1
            } else { break }
        }
        return rows
    }
}

public struct WorkspaceEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
}

public struct DirectoryListing: Sendable {
    public let entries: [WorkspaceEntry]
    public let truncated: Bool
}
