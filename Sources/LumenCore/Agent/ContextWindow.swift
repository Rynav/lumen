import Foundation

/// How much of a model's context window a conversation may use, and when the
/// older turns must be folded into a summary. Providers do not publish window
/// sizes, so a prefix table covers the known families and everything else gets a
/// conservative default.
public enum ContextWindow {
    /// The share of the window a request may fill; the rest absorbs the reply,
    /// the system prompt and estimation error.
    public static let usableFraction = 0.75

    /// shortcut: prefix table, move to catalog metadata when providers publish
    /// window sizes through their model lists.
    public static func tokens(for model: String) -> Int {
        let id = model.lowercased()
        if id.contains("gemini") { return 1_048_576 }
        if id.contains("gpt-4.1") || id.contains("gpt-4.5") { return 1_047_576 }
        if id.contains("gpt-5") || id.contains("gpt-6") || id.contains("codex") { return 272_000 }
        if id.contains("o3") || id.contains("o4") { return 200_000 }
        if id.contains("claude") { return 200_000 }
        if id.contains("kimi") { return 262_144 }
        return 128_000
    }

    /// True when the request is within the share of the window a turn may use.
    public static func fits(_ messages: [Message], model: String) -> Bool {
        estimate(messages) <= Int(Double(tokens(for: model)) * usableFraction)
    }

    /// Leading messages to fold into a summary, cutting at a user message in the
    /// older half so no kept assistant turn loses the tool results that answer its
    /// calls. Nil when the array is too short or has no such boundary.
    public static func coverage(of messages: [Message]) -> Int? {
        guard messages.count >= 2 else { return nil }
        let midpoint = messages.count / 2
        guard let boundary = messages[..<midpoint].lastIndex(where: { $0.role == .user }), boundary > 0 else { return nil }
        return boundary
    }

    /// Cheap approximation: about four characters per token, plus message overhead.
    /// Opaque provider items count too, because encrypted reasoning is the largest
    /// hidden payload in a ChatGPT-plan conversation.
    public static func estimate(_ messages: [Message]) -> Int {
        var characters = 0
        for message in messages {
            characters += 8
            for part in message.parts {
                switch part {
                case .text(let text): characters += text.count
                case .reasoningSummary(_, let text): characters += text.count
                case .toolCall(let call): characters += call.name.count + call.arguments.count
                case .toolResult(let result): characters += result.content.count
                case .providerItem(let item): characters += size(of: item)
                // Providers charge a small fixed amount per image, not its byte size.
                case .image: characters += 8_000
                }
            }
        }
        return characters / 4
    }

    /// The one tool-free request that turns a covered prefix into a standing note.
    public static let summaryInstruction = """
    You compress one coding-agent conversation that is close to its context limit. Write a single factual \
    summary another model can continue from: the task and its constraints, decisions made, files inspected or \
    changed with their paths, commands run and what they proved, what is verified, and what is unfinished. Never \
    mention that a summary was written and never call tools. Reply with the summary only.
    """
    public static let summaryRequest = "Summarize the conversation above so it can continue."

    private static func size(of value: JSONValue) -> Int {
        switch value {
        case .string(let text): return text.count
        case .number, .bool, .null: return 8
        case .array(let items): return items.reduce(0) { $0 + size(of: $1) }
        case .object(let entries): return entries.reduce(0) { $0 + $1.key.count + size(of: $1.value) }
        }
    }
}
