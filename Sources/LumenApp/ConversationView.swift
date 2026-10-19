import AppKit
import LumenCore
import SwiftUI

/// The conversation: transcript, inline approvals, and the composer.
struct ConversationView: View {
    @Bindable var chat: ChatModel
    @FocusState.Binding var composerFocused: Bool
    var chooseProject: () -> Void
    var openInspector: (InspectorTab) -> Void

    /// Assistant turns stay visible while they stream, even before text arrives,
    /// so reasoning and tool activity are not hidden behind the first token.
    private var visibleMessages: [Message] {
        chat.messages.filter {
            $0.role == .user || ($0.role == .assistant && (!$0.text.isEmpty || $0.hasReasoning || !toolCalls(for: $0).isEmpty))
        }
    }

    private var actionsByMessage: [UUID: [AgentAction]] {
        AgentAction.byMessage(AgentAction.summarize(chat.messages, isRunning: chat.isRunning,
                                                    awaitingApproval: chat.isAwaitingApproval))
    }

    private func toolCalls(for message: Message) -> [AgentAction] {
        message.role == .assistant ? (actionsByMessage[message.id] ?? []) : []
    }

    /// The last assistant turn already shows its own reasoning/tool progress, so a
    /// separate spinner would only duplicate it.
    private var showsInlineProgress: Bool {
        guard let last = chat.messages.last(where: { $0.role == .assistant }) else { return false }
        return last.hasReasoning || !toolCalls(for: last).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = chat.error { errorBar(error) }
            Composer(chat: chat, focused: $composerFocused, openInspector: openInspector)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LumenStyle.space5) {
                    if chat.messages.isEmpty { welcome }
                    ForEach(visibleMessages) { message in
                        MessageRow(message: message,
                                   actions: toolCalls(for: message),
                                   isStreaming: chat.isRunning && message.id == chat.messages.last?.id,
                                   reviewAction: { openInspector(.activity) })
                    }
                    approvals
                    if chat.isRunning && (chat.isAwaitingApproval || !showsInlineProgress) { runningIndicator }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LumenStyle.space6)
                .padding(.vertical, LumenStyle.space5)
            }
            .onChange(of: chat.messages) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label(chat.workspace == nil ? "Ask Lumen anything" : "Work in this project",
                  systemImage: chat.workspace == nil ? "bubble.left.and.bubble.right" : "hammer")
        } description: {
            Text(chat.workspace == nil
                 ? "Start a conversation, or open a project to let Lumen read files, propose edits, and run commands."
                 : "Ask about the code, propose a change, or run the tests. Every edit and command waits for your approval.")
        } actions: {
            if chat.workspace == nil {
                Button("Open a Project…") { chooseProject() }
            } else {
                Button("Explore the codebase") { chat.draft = "Explain how this project is organized" }
                Button("Find the tests") { chat.draft = "Find the tests and explain what they cover" }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LumenStyle.space6)
    }

    @ViewBuilder private var approvals: some View {
        if let proposal = chat.pendingEdit {
            EditApprovalView(proposal: proposal, decide: { chat.decideEdit(approved: $0) })
                .id(proposal.id)
        } else if let proposal = chat.pendingCommand {
            CommandApprovalView(proposal: proposal, decide: { chat.decideCommand(approved: $0) },
                                stop: { chat.stop() })
                .id(proposal.id)
        }
    }

    private var runningIndicator: some View {
        HStack(spacing: LumenStyle.space2) {
            ProgressView().controlSize(.small)
            Text("Waiting for your review…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func errorBar(_ error: String) -> some View {
        NoteView(message: error) { chat.error = nil }
            .padding(.horizontal, LumenStyle.space4)
            .padding(.vertical, LumenStyle.space2)
    }
}

/// A message row. User turns are right-aligned on a quiet fill. Assistant turns
/// keep the answer prominent and fold everything else — reasoning and tool
/// activity — into quiet, collapsed rows so the response stays readable.
private struct MessageRow: View {
    let message: Message
    var actions: [AgentAction] = []
    var isStreaming = false
    var reviewAction: () -> Void = {}

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: LumenStyle.space2) {
                let images = message.images
                if !images.isEmpty {
                    VStack(alignment: .trailing, spacing: LumenStyle.space1) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            if let nsImage = NSImage(data: image.data) {
                                Image(nsImage: nsImage)
                                    .resizable().scaledToFit()
                                    .frame(maxWidth: 280, maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: LumenStyle.radiusMedium, style: .continuous))
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body).lineSpacing(3).textSelection(.enabled)
                        .padding(.horizontal, LumenStyle.space3).padding(.vertical, LumenStyle.space2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: LumenStyle.radiusMedium, style: .continuous))
                        .frame(maxWidth: 560, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: LumenStyle.space2) {
                if message.hasReasoning {
                    ReasoningPanel(text: message.reasoningSummary, isStreaming: isStreaming)
                }
                if !actions.isEmpty { ToolActivityRow(actions: actions, review: reviewAction) }
                if !message.text.isEmpty { MarkdownView(text: message.text).font(.body).lineSpacing(3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The model's reasoning, folded away by default. Opens while it streams so the
/// work in progress is visible, then stays out of the way once the answer lands.
private struct ReasoningPanel: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded = false
    @State private var userToggled = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Group {
                if text.isEmpty {
                    Text("The provider hasn't shared a readable summary.")
                } else {
                    MarkdownView(text: text)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, LumenStyle.space1)
        } label: {
            HStack(spacing: LumenStyle.space2) {
                Image(systemName: "brain")
                Text(isStreaming && text.isEmpty ? "Thinking…" : "Reasoning")
                if isStreaming { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Reasoning summary")
        .onChange(of: isStreaming, initial: true) { _, streaming in
            if !userToggled { expanded = streaming }
        }
        .onChange(of: expanded) { _, _ in
            if expanded != isStreaming { userToggled = true }
        }
    }
}

/// Tool calls, summarized as one subdued line: the turn's actions at a glance,
/// with details one click away in the inspector instead of mid-transcript.
private struct ToolActivityRow: View {
    let actions: [AgentAction]
    var review: () -> Void

    private var isWorking: Bool {
        actions.contains { $0.status == .running || $0.status == .queued || $0.status == .review }
    }

    private var needsReview: Bool { actions.contains { $0.status == .review } }

    private var summary: String {
        var counts: [(String, Int)] = []
        for action in actions where !counts.contains(where: { $0.0 == action.title }) {
            counts.append((action.title, actions.filter { $0.title == action.title }.count))
        }
        return counts.map { $0.1 == 1 ? $0.0 : "\($0.0) ×\($0.1)" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LumenStyle.space2) {
            Image(systemName: LumenStyle.toolSymbol(actions.first?.toolName ?? ""))
                .frame(width: 16)
            Text(summary).lineLimit(2).truncationMode(.tail)
            if isWorking { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
            Button(needsReview ? "Review" : "Details", action: review)
                .buttonStyle(.borderless)
                .help(needsReview ? "Review the proposed action" : "Inspect tool output in the Activity panel")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tool activity: \(summary)")
    }
}
