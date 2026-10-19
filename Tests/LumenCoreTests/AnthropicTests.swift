import Foundation
import Testing
@testable import LumenCore

@Suite struct AnthropicTests {
    private func profile(_ base: String = "https://api.anthropic.com") -> ProviderProfile {
        ProviderProfile(name: "Claude", kind: .anthropic, baseURL: base, defaultModel: "claude-test")
    }

    @Test func requestBodyExtractsSystemAndMergesToolResults() throws {
        let call = ToolCall(id: "call_a", name: "read_file", arguments: #"{"path":"a"}"#)
        let data = try AnthropicProvider.requestBody(messages: [
            Message(role: .system, text: "Help"),
            Message(role: .user, text: "Read a"),
            Message(role: .assistant, parts: [.text("Sure"), .toolCall(call)]),
            Message(role: .tool, parts: [.toolResult(ToolResult(callID: "call_a", content: "Contents"))]),
            Message(role: .user, text: "Next")
        ], model: "claude-test", tools: [ToolDefinition(name: "read_file", description: "Read", parameters: .object(["type": .string("object")]))])
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["model"] == .string("claude-test"))
        #expect(value["stream"] == .bool(true))
        #expect(value["max_tokens"] == .number(8192))
        #expect(value["system"] == .string("Help"))
        let messages = value["messages"]?.array ?? []
        #expect(messages.count == 4)
        #expect(messages[0]["role"] == .string("user"))
        #expect(messages[1]["content"]?.array?.first?["type"] == .string("text"))
        #expect(messages[1]["content"]?.array?[1]["type"] == .string("tool_use"))
        #expect(messages[1]["content"]?.array?[1]["name"] == .string("read_file"))
        #expect(messages[1]["content"]?.array?[1]["input"]?["path"] == .string("a"))
        #expect(messages[2]["role"] == .string("user"))
        #expect(messages[2]["content"]?.array?.first?["type"] == .string("tool_result"))
        #expect(messages[2]["content"]?.array?.first?["tool_use_id"] == .string("call_a"))
        #expect(messages[3]["content"]?.array?.first?["type"] == .string("text"))
        #expect(value["tools"]?.array?.first?["input_schema"]?["type"] == .string("object"))
    }

    @Test func consecutiveToolResultsShareOneUserMessage() throws {
        let data = try AnthropicProvider.requestBody(messages: [
            Message(role: .assistant, parts: [.toolCall(ToolCall(id: "a", name: "x", arguments: "{}")), .toolCall(ToolCall(id: "b", name: "y", arguments: "{}"))]),
            Message(role: .tool, parts: [.toolResult(ToolResult(callID: "a", content: "1"))]),
            Message(role: .tool, parts: [.toolResult(ToolResult(callID: "b", content: "2"))])
        ], model: "m", tools: [])
        let messages = try JSONDecoder().decode(JSONValue.self, from: data)["messages"]?.array ?? []
        #expect(messages.count == 2)
        #expect(messages[1]["content"]?.array?.count == 2)
        #expect(messages[1]["content"]?.array?.compactMap { $0["tool_use_id"] } == [.string("a"), .string("b")])
    }

    @Test func textUsageAndCompletion() throws {
        var decoder = AnthropicProvider.StreamDecoder()
        let fixture = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello 🌍"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","usage":{"output_tokens":3}}"#,
            #"{"type":"message_stop"}"#
        ]
        var decoded: [StreamEvent] = []
        for line in fixture { decoded += try decoder.consume(line) }
        try decoder.finish()
        #expect(decoded == [.text("Hello 🌍"), .usage(TokenUsage(inputTokens: 12, outputTokens: 3)), .finished])
    }

    @Test func toolUseAggregatesPartialJSON() throws {
        var decoder = AnthropicProvider.StreamDecoder()
        #expect(try decoder.consume(#"{"type":"message_start","message":{"usage":{"input_tokens":5}}}"#).isEmpty)
        #expect(try decoder.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_a","name":"read_file"}}"#).isEmpty)
        #expect(try decoder.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#).isEmpty)
        #expect(try decoder.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"a\"}"}}"#).isEmpty)
        #expect(try decoder.consume(#"{"type":"content_block_stop","index":0}"#) == [
            .toolCall(ToolCall(id: "call_a", name: "read_file", arguments: #"{"path":"a"}"#))
        ])
        _ = try decoder.consume(#"{"type":"message_delta","usage":{"output_tokens":7}}"#)
        #expect(try decoder.consume(#"{"type":"message_stop"}"#) == [.finished])
        try decoder.finish()
    }

    @Test func invalidAndTruncatedEvents() throws {
        var decoder = AnthropicProvider.StreamDecoder()
        #expect(throws: ProviderError.malformedStream) { try decoder.consume("not json") }
        #expect(throws: ProviderError.http(400)) {
            try decoder.consume(#"{"type":"error","error":{"type":"invalid_request_error","message":"secret"}}"#)
        }
        var truncated = AnthropicProvider.StreamDecoder()
        _ = try truncated.consume(#"{"type":"message_start","message":{"usage":{"input_tokens":1}}}"#)
        #expect(throws: ProviderError.incompleteStream) { try truncated.finish() }
        var badTool = AnthropicProvider.StreamDecoder()
        _ = try badTool.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"x"}}"#)
        _ = try badTool.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}"#)
        #expect(throws: ProviderError.malformedStream) { try badTool.consume(#"{"type":"content_block_stop","index":0}"#) }
    }

    @Test func imagePartsEncodeAsAnthropicBase64Blocks() throws {
        let image = ImageAttachment(mediaType: "image/jpeg", data: Data([0x01, 0x02]))
        let data = try AnthropicProvider.requestBody(messages: [
            Message(role: .user, parts: [.text("Look"), .image(image)])
        ], model: "claude-test", tools: [])
        let messages = try JSONDecoder().decode(JSONValue.self, from: data)["messages"]?.array ?? []
        let blocks = messages[0]["content"]?.array ?? []
        #expect(blocks[0]["type"] == .string("text"))
        #expect(blocks[1]["type"] == .string("image"))
        #expect(blocks[1]["source"]?["type"] == .string("base64"))
        #expect(blocks[1]["source"]?["media_type"] == .string("image/jpeg"))
        #expect(blocks[1]["source"]?["data"] == .string(image.data.base64EncodedString()))
    }

    @Test func endpointsAndHeaders() throws {
        let provider = try AnthropicProvider(profile: profile(), apiKey: "secret", headers: ["X-Custom": "value", "x-api-key": "wrong"])
        let request = provider.request(path: "v1/messages", body: Data("{}".utf8))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
        let withV1 = try AnthropicProvider(profile: profile("https://api.anthropic.com/v1"), apiKey: "k", headers: [:])
        #expect(withV1.request(path: "v1/models", query: "limit=1000").url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
    }
}
