import Foundation

public enum AgentEvent: Sendable {
    case message(Message)
    /// Token usage for one provider request plus that request's stream duration,
    /// so callers can report output tokens per second.
    case usage(TokenUsage, seconds: Double)
    case approval(FileEditProposal)
    case editBatch(EditBatchProposal)
    case applied(AppliedChange)
    case commandApproval(CommandProposal)
    case command(CommandUpdate)
    case question(UserQuestion)
    case todos([TodoItem])
}

public actor AgentSession {
    public init() {}

    /// Keep the next request valid if Stop or a stream failure interrupted a tool turn.
    public nonisolated static func completingToolResults(in messages: [Message]) -> [Message] {
        var completed: [Message] = []
        for (index, message) in messages.enumerated() {
            completed.append(message)
            guard message.role == .assistant else { continue }
            var answered: Set<String> = []
            for following in messages.dropFirst(index + 1) {
                guard following.role == .tool else { break }
                for part in following.parts {
                    if case .toolResult(let result) = part { answered.insert(result.callID) }
                }
            }
            // All results stay adjacent to their assistant's tool calls.
            let missing = message.parts.compactMap { part -> ToolResult? in
                guard case .toolCall(let call) = part, !answered.contains(call.id) else { return nil }
                return ToolResult(callID: call.id, content: "Tool execution was interrupted. Retry if needed.", isError: true)
            }
            if !missing.isEmpty {
                completed.append(Message(role: .tool, parts: missing.map(ContentPart.toolResult)))
            }
        }
        return completed
    }

    public nonisolated func run(messages: [Message], model: String, provider: any LLMProvider,
                               workspace: WorkspaceService?, maxIterations: Int, approval: ApprovalGate? = nil,
                               planMode: Bool = false,
                               extraTools: [ToolDefinition] = [],
                               executeExtraTool: (@Sendable (ToolCall) async -> ToolResult?)? = nil) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let task = Task {
                do {
                    try await self.execute(messages: messages, model: model, provider: provider,
                                           workspace: workspace, maxIterations: maxIterations, approval: approval,
                                           planMode: planMode, extraTools: extraTools,
                                           executeExtraTool: executeExtraTool, output: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func execute(messages: [Message], model: String, provider: any LLMProvider,
                         workspace: WorkspaceService?, maxIterations: Int, approval: ApprovalGate?,
                         planMode: Bool, extraTools: [ToolDefinition],
                         executeExtraTool: (@Sendable (ToolCall) async -> ToolResult?)?,
                         output: AsyncThrowingStream<AgentEvent, any Error>.Continuation) async throws {
        var history = messages
        let registry = workspace.map { ToolRegistry(workspace: $0, planMode: planMode) }
        // MCP tools can change things outside Lumen's knowledge, so planning never
        // advertises or runs them.
        let extra = planMode ? [] : extraTools
        let advertised = (registry == nil ? [] : ToolRegistry.definitions(approvalIsEnabled: approval != nil, planMode: planMode)) + extra
        let iterations = max(1, min(maxIterations, 1_000))
        for iteration in 0..<iterations {
            try Task.checkCancellation()
            // The final permitted request advertises no tools and asks for a
            // summary, so an exhausted agent still answers instead of failing.
            let exhausted = iteration == iterations - 1
            let tools = exhausted ? [] : advertised
            let request = exhausted ? history + [Message(role: .assistant, text: SystemPrompt.maxSteps)] : history
            var response = Message(role: .assistant, parts: [])
            var calls: [ToolCall] = []
            let streamStarted = ContinuousClock.now
            for try await event in provider.stream(messages: request, model: model, tools: tools) {
                try Task.checkCancellation()
                switch event {
                case .text(let text):
                    if case .text(let previous) = response.parts.last {
                        response.parts[response.parts.count - 1] = .text(previous + text)
                    } else { response.parts.append(.text(text)) }
                    output.yield(.message(response))
                case .reasoningSummary(let id, let text):
                    let part = ContentPart.reasoningSummary(id: id, text: text)
                    if let index = response.parts.firstIndex(where: {
                        if case .reasoningSummary(let existingID, _) = $0 { return existingID == id }
                        return false
                    }) { response.parts[index] = part }
                    else { response.parts.append(part) }
                    output.yield(.message(response))
                case .toolCall(let call):
                    guard calls.count < 32, !calls.contains(where: { $0.id == call.id }) else {
                        throw AgentError.invalidToolCalls
                    }
                    calls.append(call)
                    response.parts.append(.toolCall(call))
                    output.yield(.message(response))
                case .providerItem(let item):
                    response.parts.append(.providerItem(item))
                    output.yield(.message(response))
                case .usage(let usage):
                    output.yield(.usage(usage, seconds: TokenRate.seconds(streamStarted.duration(to: ContinuousClock.now))))
                case .finished: break
                }
            }
            history.append(response)
            guard !calls.isEmpty else { return }
            if exhausted {
                // Tools are withheld on the final request, so a tool call here is a
                // model error. Refuse it rather than running an unreviewed action.
                for call in calls {
                    let message = Message(role: .tool, parts: [.toolResult(ToolResult(callID: call.id, content: ToolResult.toolsDisabled, isError: true))])
                    history.append(message)
                    output.yield(.message(message))
                }
                return
            }
            for call in calls {
                try Task.checkCancellation()
                let result: ToolResult
                if !planMode, call.name.hasPrefix("mcp__"), let executeExtraTool, let extra = await executeExtraTool(call) {
                    result = extra
                } else if let registry {
                    result = try await registry.execute(call, approval: approval,
                        onProposal: { output.yield(.approval($0)) },
                        onBatchProposal: { output.yield(.editBatch($0)) },
                        onApplied: { output.yield(.applied($0)) },
                        onCommandProposal: { output.yield(.commandApproval($0)) }, onCommandUpdate: { output.yield(.command($0)) },
                        onQuestion: { output.yield(.question($0)) }, onTodos: { output.yield(.todos($0)) })
                }
                else { result = ToolResult(callID: call.id, content: "Open a project folder to use tools.", isError: true) }
                let message = Message(role: .tool, parts: [.toolResult(result)])
                history.append(message)
                output.yield(.message(message))
            }
        }
        // Unreachable: the final iteration returns above.
        throw AgentError.iterationLimit
    }
}

public enum AgentError: LocalizedError {
    case iterationLimit, invalidToolCalls
    public var errorDescription: String? {
        switch self {
        case .iterationLimit: "The agent reached its iteration limit. Send another message to continue."
        case .invalidToolCalls: "The provider returned too many or duplicate tool calls."
        }
    }
}
