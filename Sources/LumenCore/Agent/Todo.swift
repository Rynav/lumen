import Foundation

/// One step in the checklist the agent maintains with `update_todos`. The whole
/// list is replaced on each update, so the order is the plan's order.
public struct TodoItem: Codable, Equatable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    public var status: Status

    public init(content: String, status: Status = .pending) {
        self.content = content
        self.status = status
    }
}
