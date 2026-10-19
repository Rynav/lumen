import Foundation

public struct AgentAction: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable {
        case queued = "Queued", running = "Working", review = "Needs approval"
        case completed = "Done", failed = "Needs attention", declined = "Declined", stopped = "Stopped"
    }

    public let id: String
    /// The assistant message whose tool call this action came from.
    public let messageID: UUID
    public let toolName: String
    public let title: String
    public let target: String
    public fileprivate(set) var status: Status
    public fileprivate(set) var result: ToolResult?

    public static func summarize(_ messages: [Message], isRunning: Bool, awaitingApproval: Bool) -> [Self] {
        var actions: [Self] = []
        var indices: [String: Int] = [:]
        var currentTurn: [Int] = []
        for message in messages {
            if message.role == .assistant || message.role == .user { currentTurn = []; indices = [:] }
            for part in message.parts {
                if message.role == .assistant, case .toolCall(let call) = part {
                    let args = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)))
                    let title: String
                    let target: String
                    switch call.name {
                    case "list_files": title = "Explore files"; target = args?["path"]?.string ?? "Project folder"
                    case "read_file": title = "Read file"; target = args?["path"]?.string ?? "Project file"
                    case "search_files": title = "Search code"; target = args?["query"]?.string ?? "Project files"
                    case "edit_file": title = "Update file"; target = args?["path"]?.string ?? "Project file"
                    case "run_command": title = "Run command"; target = args?["executable"]?.string ?? "Project command"
                    default:
                        let mcp = call.name.hasPrefix("mcp__") ? call.name.dropFirst(5) : nil
                        let parts = mcp?.split(separator: "__", maxSplits: 1) ?? []
                        title = mcp == nil ? "Project action" : "Use tool"
                        target = parts.count == 2 ? "\(parts[1]) · \(parts[0])"
                            : mcp == nil ? call.name.replacingOccurrences(of: "_", with: " ") : call.name
                    }
                    indices[call.id] = actions.count
                    currentTurn.append(actions.count)
                    actions.append(Self(id: "\(message.id.uuidString):\(call.id)", messageID: message.id,
                                        toolName: call.name, title: title, target: target, status: .stopped))
                } else if message.role == .tool, case .toolResult(let result) = part, let index = indices[result.callID] {
                    actions[index].result = result
                    if !result.isError { actions[index].status = .completed }
                    else if result.content.hasPrefix("The user rejected") { actions[index].status = .declined }
                    else if result.content.hasPrefix("Tool execution was interrupted") || result.content.hasPrefix("Cancelled.") {
                        actions[index].status = .stopped
                    } else { actions[index].status = .failed }
                }
            }
        }
        if isRunning {
            let pending = currentTurn.filter { actions[$0].result == nil }
            for (offset, index) in pending.enumerated() {
                actions[index].status = offset == 0 ? (awaitingApproval ? .review : .running) : .queued
            }
        }
        return actions
    }

    /// Groups actions by the assistant message that requested them, so each turn
    /// can summarize its own tool activity.
    public static func byMessage(_ actions: [Self]) -> [UUID: [Self]] {
        Dictionary(grouping: actions, by: \.messageID)
    }
}
