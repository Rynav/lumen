import Foundation
import Testing
@testable import LumenCore

@Suite struct ActivityTests {
    @Test func actionsUseReadableLabelsAndAccurateStates() {
        let read = ToolCall(id: "read", name: "read_file", arguments: #"{"path":"Sources/App.swift"}"#)
        let edit = ToolCall(id: "edit", name: "edit_file", arguments: #"{"path":"Sources/App.swift","old_text":"old","new_text":"new"}"#)
        let command = ToolCall(id: "run", name: "run_command", arguments: #"{"executable":"swift","arguments":["test"]}"#)
        var messages = [Message(role: .assistant, parts: [.toolCall(read), .toolCall(edit), .toolCall(command)]),
                        Message(role: .tool, parts: [.toolResult(ToolResult(callID: "read", content: "source"))])]
        var actions = AgentAction.summarize(messages, isRunning: true, awaitingApproval: true)
        #expect(actions.map(\.status) == [.completed, .review, .queued])
        #expect(actions.map(\.title) == ["Read file", "Update file", "Run command"])
        #expect(actions.map(\.target) == ["Sources/App.swift", "Sources/App.swift", "swift"])
        messages.append(Message(role: .tool, parts: [.toolResult(ToolResult(callID: "edit", content: "The user rejected this edit.", isError: true)),
                                                   .toolResult(ToolResult(callID: "run", content: "Exit code 1.", isError: true))]))
        actions = AgentAction.summarize(messages, isRunning: false, awaitingApproval: false)
        #expect(actions.map(\.status) == [.completed, .declined, .failed])
        #expect(actions[2].result?.content == "Exit code 1.")
    }

    @Test func repeatedIDsAcrossTurnsAndInterruptedActionsStayDistinct() {
        let call = ToolCall(id: "reused", name: "list_files", arguments: "{}")
        let messages = [Message(role: .assistant, parts: [.toolCall(call)]),
                        Message(role: .tool, parts: [.toolResult(ToolResult(callID: "reused", content: "Tool execution was interrupted.", isError: true))]),
                        Message(role: .user, text: "Try again"),
                        Message(role: .assistant, parts: [.toolCall(call)])]
        let actions = AgentAction.summarize(messages, isRunning: true, awaitingApproval: false)
        #expect(actions[0].id != actions[1].id)
        #expect(actions.map(\.status) == [.stopped, .running])
        #expect(AgentAction.summarize(messages, isRunning: false, awaitingApproval: false).last?.status == .stopped)
        let malformed = [Message(role: .assistant, parts: [.toolCall(ToolCall(id: "bad", name: "read_file", arguments: "invalid"))])]
        #expect(AgentAction.summarize(malformed, isRunning: false, awaitingApproval: false).first?.target == "Project file")
        #expect(AgentAction.summarize([Message(role: .user, text: "Hello")], isRunning: false, awaitingApproval: false).isEmpty)
    }

    @Test func actionsKeepTheirRequestingMessageSoTurnsCanBeSummarizedSeparately() {
        let read = ToolCall(id: "read", name: "read_file", arguments: #"{"path":"README.md"}"#)
        let mcp = ToolCall(id: "mcp", name: "mcp__filesystem__read_text_file", arguments: "{}")
        let first = Message(role: .assistant, parts: [.toolCall(read)])
        let second = Message(role: .assistant, parts: [.toolCall(mcp), .toolCall(ToolCall(id: "run", name: "run_command", arguments: #"{"executable":"swift","arguments":["test"]}"#))])
        let messages = [first, second, Message(role: .tool, parts: [.toolResult(ToolResult(callID: "read", content: "source"))])]
        let actions = AgentAction.summarize(messages, isRunning: false, awaitingApproval: false)
        #expect(actions.map(\.messageID) == [first.id, second.id, second.id])
        let grouped = AgentAction.byMessage(actions)
        #expect(grouped[first.id]?.map(\.title) == ["Read file"])
        #expect(grouped[second.id]?.count == 2)
        #expect(actions[1].title == "Use tool")
        #expect(actions[1].target == "read_text_file · filesystem")
        #expect(grouped[UUID()] == nil)
    }

    @Test func reasoningAloneStillMarksAnAssistantTurnAsWorthShowing() {
        let thinking = Message(role: .assistant, parts: [.reasoningSummary(id: "rs:0", text: "Weighing options")])
        #expect(thinking.hasReasoning)
        #expect(thinking.text.isEmpty)
        #expect(thinking.reasoningSummary == "Weighing options")
        #expect(Message(role: .assistant, parts: [.reasoningSummary(id: "rs:0", text: "")]).hasReasoning)
        #expect(!Message(role: .assistant, parts: [.text("Answer")]).hasReasoning)
    }
}
