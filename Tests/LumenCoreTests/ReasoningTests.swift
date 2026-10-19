import Foundation
import Testing
@testable import LumenCore

@Suite struct ReasoningTests {
    @Test func summariesAreRequestedWithoutOverridingDefaultEffort() throws {
        for model in ["gpt-5.4", "gpt-6.1-sol", "o3", "o4-mini", "codex-mini-latest"] {
            let body = try JSONDecoder().decode(JSONValue.self, from: ChatGPTProvider.requestBody(messages: [], model: model, tools: []))
            #expect(body["reasoning"]?["summary"] == .string("auto"))
            #expect(body["reasoning"]?["effort"] == nil)
        }
        let high = try JSONDecoder().decode(JSONValue.self, from: ChatGPTProvider.requestBody(messages: [], model: "gpt-6.1-sol", tools: [], reasoning: .high))
        #expect(high["reasoning"]?["effort"] == .string("high"))
        #expect(high["reasoning"]?["summary"] == .string("auto"))
        let legacy = try JSONDecoder().decode(JSONValue.self, from: ChatGPTProvider.requestBody(messages: [], model: "gpt-4.1", tools: []))
        #expect(legacy["reasoning"] == nil)
    }

    @Test func streamingSummarySnapshotsDoNotDuplicateFinalText() throws {
        var decoder = ChatGPTProvider.StreamDecoder()
        #expect(try decoder.consume(#"{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}"#) == [.reasoningSummary(id: "rs_1:0", text: "")])
        #expect(try decoder.consume(#"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"Checking "}"#) == [.reasoningSummary(id: "rs_1:0", text: "Checking ")])
        #expect(try decoder.consume(#"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"the source."}"#) == [.reasoningSummary(id: "rs_1:0", text: "Checking the source.")])
        #expect(try decoder.consume(#"{"type":"response.reasoning_summary_part.added","item_id":"rs_1","summary_index":0,"part":{"type":"summary_text","text":""}}"#) == [.reasoningSummary(id: "rs_1:0", text: "Checking the source.")])
        #expect(try decoder.consume(#"{"type":"response.reasoning_summary_text.done","item_id":"rs_1","summary_index":0,"text":"Checking the source."}"#) == [.reasoningSummary(id: "rs_1:0", text: "Checking the source.")])
        #expect(try decoder.consume(#"{"type":"response.reasoning_summary_part.done","item_id":"rs_1","summary_index":0,"part":{"type":"summary_text","text":"Checking the source."}}"#) == [.reasoningSummary(id: "rs_1:0", text: "Checking the source.")])
        let completed = try decoder.consume(#"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque-do-not-render","summary":[{"type":"summary_text","text":"Checking the source."},{"type":"summary_text","text":"Reviewing the tests."}]}}"#)
        #expect(completed.count == 3)
        #expect(completed[0] == .reasoningSummary(id: "rs_1:0", text: "Checking the source."))
        #expect(completed[1] == .reasoningSummary(id: "rs_1:1", text: "Reviewing the tests."))
        guard case .providerItem(let original) = completed[2] else { Issue.record("Opaque continuation item was lost"); return }
        #expect(original["encrypted_content"]?.string == "opaque-do-not-render")
    }

    @Test func completeSummaryWorksWithoutDeltasAndRejectsMalformedIndices() throws {
        var decoder = ChatGPTProvider.StreamDecoder()
        let result = try decoder.consume(#"{"type":"response.reasoning_summary_text.done","item_id":"rs_2","summary_index":0,"text":"A supplied summary."}"#)
        #expect(result == [.reasoningSummary(id: "rs_2:0", text: "A supplied summary.")])
        #expect(throws: ProviderError.malformedStream) {
            try decoder.consume(#"{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":1.5,"delta":"bad"}"#)
        }
    }

    @Test func compatibleProvidersExposeReasoningSeparatelyFromAnswer() throws {
        var decoder = OpenAIProvider.StreamDecoder()
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"reasoning_content":"Inspecting "}}]}"#) == [.reasoningSummary(id: "compatible:0", text: "Inspecting ")])
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"reasoning":"the test.","content":"Answer"}}]}"#) == [.reasoningSummary(id: "compatible:0", text: "Inspecting the test."), .text("Answer")])
        #expect(try decoder.consume(#"{"choices":[{"index":0,"delta":{"reasoning":{"unsupported":true},"content":" text"}}]}"#) == [.text(" text")])
    }

    @Test func reasoningIsNotAnAnswerOrAnExtraPromptAndOpaqueContentIsNeverDisplayed() throws {
        let opaque = JSONValue.object(["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string("opaque-do-not-render")])
        let message = Message(role: .assistant, parts: [.reasoningSummary(id: "rs_1:0", text: "Public summary"), .providerItem(opaque), .text("Answer")])
        #expect(message.text == "Answer")
        #expect(message.reasoningSummary == "Public summary")
        #expect(message.hasReasoning)
        #expect(Message(role: .assistant, parts: [.providerItem(opaque)]).reasoningSummary.isEmpty)
        #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)) == message)
        let response = try JSONDecoder().decode(JSONValue.self, from: ChatGPTProvider.requestBody(messages: [message], model: "gpt-6.1-sol", tools: []))
        #expect(response["input"]?.array?.count == 2)
        #expect(response["input"]?.array?.first == opaque)
        #expect(response["input"]?.array?.last?["content"] == .string("Answer"))
        let compatible = try JSONDecoder().decode(JSONValue.self, from: OpenAIProvider.requestBody(messages: [message], model: "test", tools: []))
        #expect(compatible["messages"]?.array?.first?["content"] == .string("Answer"))
        let interrupted = Message(role: .assistant, parts: [.reasoningSummary(id: "partial", text: "Partial public summary")])
        let nextRequest = try JSONDecoder().decode(JSONValue.self, from: OpenAIProvider.requestBody(messages: [interrupted], model: "test", tools: []))
        #expect(nextRequest["messages"]?.array?.isEmpty == true)
    }
}
