import LumenCore
import SwiftUI

/// Inspector sections, mirroring the workspace surfaces of the agent.
enum InspectorTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case changes = "Changes"
    case git = "Git"
    case files = "Files"
    var id: String { rawValue }
}

/// The workspace inspector: activity, proposed and applied changes, Git review,
/// and a read-only file explorer.
struct InspectorView: View {
    @Bindable var chat: ChatModel
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(LumenStyle.space2)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .activity: ActivitySection(chat: chat)
        case .changes: ChangesSection(chat: chat)
        case .git: GitSection(chat: chat)
        case .files: FilesSection(chat: chat)
        }
    }
}

/// A left-aligned empty state. Callers place it in a full-height container so it
/// pins to the top of the inspector instead of floating in the middle.
private struct InspectorEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LumenStyle.space4)
    }
}

// MARK: - Activity

private struct ActivitySection: View {
    @Bindable var chat: ChatModel

    private var actions: [AgentAction] {
        AgentAction.summarize(chat.messages, isRunning: chat.isRunning, awaitingApproval: chat.isAwaitingApproval)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumenStyle.space3) {
                if let proposal = chat.pendingCommand {
                    CommandApprovalView(proposal: proposal, decide: { chat.decideCommand(approved: $0) },
                                        stop: { chat.stop() })
                        .id(proposal.id)
                }
                if let question = chat.pendingQuestion {
                    QuestionView(question: question, answer: { chat.answerQuestion($0) })
                        .id(question.id)
                }
                if actions.isEmpty && chat.commands.isEmpty {
                    InspectorEmptyState(title: "No activity yet", systemImage: "checklist",
                                        message: "File reads, searches, edits, and commands appear here as Lumen works.")
                }
                if !actions.isEmpty {
                    Text("\(actions.count) actions · \(actions.filter { $0.status == .completed }.count) completed")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(actions) { ActionRow(action: $0) }
                }
                if !chat.commands.isEmpty {
                    Text("Command output").font(.subheadline.weight(.semibold)).padding(.top, LumenStyle.space2)
                    ForEach(chat.commands) { CommandConsoleView(command: $0) }
                }
            }
            .padding(LumenStyle.space4)
        }
    }
}

private struct ActionRow: View {
    let action: AgentAction
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let result = action.result {
                Text(String(result.content.prefix(6_000)))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, LumenStyle.space1)
                if result.content.count > 6_000 {
                    Text("Showing the first 6,000 characters.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(action.status == .review ? "Review the proposed action above to continue." : action.status.rawValue)
                    .font(.caption).foregroundStyle(.secondary).padding(.top, LumenStyle.space1)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: LumenStyle.space2) {
                Image(systemName: LumenStyle.toolSymbol(action.toolName)).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title).font(.callout)
                    Text(action.target).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if action.status == .running { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: LumenStyle.statusSymbol(action.status)).font(.caption)
                        .foregroundStyle(LumenStyle.statusColor(action.status))
                }
            }
        }
        .padding(LumenStyle.space2)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Changes

private struct ChangesSection: View {
    @Bindable var chat: ChatModel
    @State private var selectedChangeID: UUID?
    @State private var expandingDiff = false

    var body: some View {
        Group {
            if let batch = chat.pendingEditBatch {
                ScrollView {
                    EditBatchApprovalView(batch: batch, approved: $chat.pendingEditSelection,
                                          decide: { chat.decideEditBatch(approvedIDs: $0) })
                        .id(batch.id)
                        .padding(LumenStyle.space4)
                }
            } else if let proposal = chat.pendingEdit {
                ScrollView {
                    EditApprovalView(proposal: proposal, decide: { chat.decideEdit(approved: $0) })
                        .id(proposal.id)
                        .padding(LumenStyle.space4)
                }
            } else if chat.changes.isEmpty {
                InspectorEmptyState(title: "No changes yet", systemImage: "doc.text.magnifyingglass",
                                    message: "Proposed edits appear here for review before they are applied. Applied changes can be inspected and undone.")
            } else {
                appliedList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: chat.currentConversationID) { _, _ in selectedChangeID = nil }
        .onChange(of: chat.changes.last?.id) { _, id in selectedChangeID = id }
        .sheet(isPresented: $expandingDiff) { ChangesView(chat: chat, initialSelection: selectedChangeID) }
    }

    private var appliedList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedChangeID) {
                ForEach(chat.changes) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.proposal.path).lineLimit(1).truncationMode(.middle)
                        Text(change.undone ? "Undone" : "Applied").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(change.id)
                }
            }
            .frame(maxHeight: 170)
            Divider()
            if let change = chat.changes.first(where: { $0.id == selectedChangeID }) ?? chat.changes.last {
                DiffView(proposal: change.proposal, compact: true).id(change.id)
                Divider()
                HStack {
                    Button("Expand Diff", systemImage: "arrow.up.left.and.arrow.down.right") {
                        selectedChangeID = change.id
                        expandingDiff = true
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button(chat.isUndoing ? "Undoing…" : "Undo Change") { Task { await chat.undoChange(change.id) } }
                        .disabled(chat.isBusy || change.undone)
                }
                .font(.callout)
                .padding(LumenStyle.space3)
            }
        }
    }
}

// MARK: - Git

private struct GitSection: View {
    @Bindable var chat: ChatModel
    @State private var message = ""
    @State private var showDiff = false
    @State private var committing = false

    var body: some View {
        Group {
            if chat.workspace == nil {
                InspectorEmptyState(title: "No project open", systemImage: "folder",
                                    message: "Open a project to review Git changes.")
            } else if !chat.isGitRepository {
                InspectorEmptyState(title: "Not a Git repository", systemImage: "arrow.triangle.branch",
                                    message: "This folder has no Git history to review.")
            } else {
                review
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: chat.workspaceRevision) { await chat.refreshGitReview() }
    }

    private var review: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(chat.gitStatus.count) changed file\(chat.gitStatus.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await chat.refreshGitReview() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Refresh Git status")
            }
            .padding(.horizontal, LumenStyle.space4)
            .padding(.vertical, LumenStyle.space2)
            Divider()
            if chat.gitStatus.isEmpty {
                InspectorEmptyState(title: "No changes since the last commit", systemImage: "checkmark.circle",
                                    message: "The working tree matches HEAD.")
            } else {
                List(chat.gitStatus) { entry in
                    HStack(spacing: LumenStyle.space2) {
                        Text(entry.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.isUntracked ? LumenStyle.success : LumenStyle.warning)
                            .frame(width: 60, alignment: .leading)
                        Text(entry.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            VStack(spacing: LumenStyle.space2) {
                TextField("Commit message", text: $message).textFieldStyle(.roundedBorder)
                HStack {
                    Button(committing ? "Committing…" : "Commit All") {
                        committing = true
                        Task { await chat.commitAll(message: message); message = ""; committing = false }
                    }
                    .disabled(committing || chat.isBusy || chat.gitStatus.isEmpty
                              || message.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(showDiff ? "Hide Diff" : "Show Diff") { showDiff.toggle() }
                    Spacer()
                }
            }
            .padding(LumenStyle.space4)
            if showDiff {
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Text(chat.gitDiff.isEmpty ? "No tracked diff. Untracked files appear in the list above." : chat.gitDiff)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(LumenStyle.space4)
                }
                .frame(maxHeight: 200)
            }
        }
    }
}

// MARK: - Files

private struct FilesSection: View {
    @Bindable var chat: ChatModel

    var body: some View {
        Group {
            if let workspace = chat.workspace {
                FileTreeView(workspace: workspace, revision: chat.workspaceRevision, busy: chat.isBusy,
                             onAttach: { chat.attach($0) })
                    .id(workspace.root.path)
                    .padding(LumenStyle.space3)
            } else {
                InspectorEmptyState(title: "No project open", systemImage: "folder",
                                    message: "Choose a project to browse its files.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
