import Foundation
import Testing
@testable import LumenCore

@Test func normalizedConversationRoundTrip() throws {
    let call = ToolCall(id: "call-1", name: "read_file", arguments: "{\"path\":\"README.md\"}")
    let messages = [
        Message(role: .user, text: "Read the readme"),
        Message(role: .assistant, parts: [.text("Reading."), .toolCall(call)]),
        Message(role: .tool, parts: [.toolResult(ToolResult(callID: call.id, content: "Hello"))])
    ]
    #expect(try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(messages)) == messages)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"flag\":true,\"count\":2,\"items\":[null,\"x\"]}".utf8))
    #expect(value["flag"] == .bool(true))
    #expect(value["count"]?.number == 2)
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}

@Test func tokenRateNeedsTokensAndElapsedTime() {
    #expect(TokenRate.tokensPerSecond(outputTokens: 100, seconds: 4) == 25)
    #expect(TokenRate.tokensPerSecond(outputTokens: 0, seconds: 4) == nil)
    #expect(TokenRate.tokensPerSecond(outputTokens: 100, seconds: 0) == nil)
    #expect(TokenRate.tokensPerSecond(outputTokens: 100, seconds: .infinity) == nil)
}

@Test func costRequiresBothPrices() {
    let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
    #expect(usage.estimatedCost(inputPerMillion: 2, outputPerMillion: 8) == 6)
    #expect(usage.estimatedCost(inputPerMillion: nil, outputPerMillion: 8) == nil)
    #expect(usage.estimatedCost(inputPerMillion: -1, outputPerMillion: 8) == nil)
    #expect(usage.estimatedCost(inputPerMillion: .infinity, outputPerMillion: 8) == nil)
}
