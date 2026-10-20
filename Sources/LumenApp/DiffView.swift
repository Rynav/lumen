import LumenCore
import SwiftUI

/// A before/after diff with line numbers and added/removed tinting.
struct DiffView: View {
    let proposal: FileEditProposal
    var compact = false
    var onReady: @MainActor () -> Void = {}
    @State private var rows: [DiffLine] = []
    @State private var changesOnly = false
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            HStack {
                Label(proposal.path, systemImage: proposal.before == nil ? "doc.badge.plus" : "doc.text")
                    .font(.system(compact ? .callout : .body, design: .monospaced))
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                Text("−\(rows.filter { $0.kind == .removed }.count)").foregroundStyle(LumenStyle.danger)
                Text("+\(rows.filter { $0.kind == .added }.count)").foregroundStyle(LumenStyle.success)
            }
            .font(.system(.caption, design: .monospaced))

            HStack {
                Spacer()
                Toggle("Changes only", isOn: $changesOnly).toggleStyle(.switch).controlSize(.mini).font(.caption)
            }

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(changesOnly ? rows.filter { $0.kind != .context } : rows) { row in
                        HStack(alignment: .top, spacing: LumenStyle.space2) {
                            Text(row.oldNumber.map(String.init) ?? "")
                                .frame(width: compact ? 26 : 44, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(row.newNumber.map(String.init) ?? "")
                                .frame(width: compact ? 26 : 44, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                                .frame(width: 12)
                                .foregroundStyle(row.kind == .added ? LumenStyle.success : row.kind == .removed ? LumenStyle.danger : .secondary)
                            Text(row.text.isEmpty ? " " : row.text)
                                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                            Spacer(minLength: LumenStyle.space3)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 2).padding(.horizontal, LumenStyle.space2)
                        .frame(minWidth: max(viewportWidth, compact ? 240 : 360), alignment: .leading)
                        .background(row.kind == .added ? LumenStyle.success.opacity(0.14)
                                    : row.kind == .removed ? LumenStyle.danger.opacity(0.14) : .clear)
                        .accessibilityLabel("\(row.kind == .added ? "Added" : row.kind == .removed ? "Removed" : "Unchanged") line: \(row.text)")
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DiffViewportWidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(DiffViewportWidthKey.self) { viewportWidth = $0 }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous).strokeBorder(LumenStyle.separator))
        }
        .padding(compact ? LumenStyle.space2 : 0)
        .task(id: proposal.id) {
            rows = []
            let proposal = proposal
            rows = await Task.detached { proposal.diff }.value
            onReady()
        }
    }
}

private struct DiffViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A card that asks the user to approve a proposed file change.
struct EditApprovalView: View {
    let proposal: FileEditProposal
    let decide: (Bool) -> Void
    @State private var diffReady = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: LumenStyle.space3) {
                Text("Nothing is written until you approve. A recovery snapshot is kept before applying.")
                    .font(.callout).foregroundStyle(.secondary)
                DiffView(proposal: proposal, compact: true) { diffReady = true }
                HStack {
                    Spacer()
                    Button("Reject") { decide(false) }.keyboardShortcut(.escape, modifiers: [])
                    Button("Approve & Apply") { decide(true) }.buttonStyle(.borderedProminent).disabled(!diffReady)
                }
            }
            .padding(.top, LumenStyle.space1)
        } label: {
            Label(proposal.before == nil ? "Create a new file" : "Review a proposed change",
                  systemImage: proposal.before == nil ? "doc.badge.plus" : "square.and.pencil")
        }
    }
}

/// A card that asks the user to apply selected files from one patch.
struct EditBatchApprovalView: View {
    let batch: EditBatchProposal
    @Binding var approved: Set<UUID>
    let decide: (Set<UUID>) -> Void
    @State private var expanded: Set<UUID> = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: LumenStyle.space3) {
                Text("Nothing is written until you apply. Unchecked files are rejected; applied files keep recovery snapshots.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(spacing: LumenStyle.space2) {
                    ForEach(batch.edits) { edit in fileRow(edit) }
                }
                HStack {
                    Text("\(approved.count) of \(batch.edits.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reject All") { decide([]) }.keyboardShortcut(.escape, modifiers: [])
                    Button(applyTitle) { decide(approved) }
                        .buttonStyle(.borderedProminent)
                        .disabled(approved.isEmpty)
                }
            }
            .padding(.top, LumenStyle.space1)
        } label: {
            Label(batch.edits.count == 1 ? "Review 1 file change" : "Review \(batch.edits.count) file changes",
                  systemImage: "square.and.pencil")
        }
    }

    private var applyTitle: String {
        approved.count == 1 ? "Apply 1 File" : "Apply \(approved.count) Files"
    }

    private func fileRow(_ edit: FileEditProposal) -> some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            HStack(spacing: LumenStyle.space2) {
                Toggle("", isOn: binding(for: edit.id)).labelsHidden().toggleStyle(.checkbox)
                    .accessibilityLabel("Apply \(edit.path)")
                Label(edit.path, systemImage: edit.before == nil ? "doc.badge.plus" : edit.after == nil ? "trash" : "doc.text")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2).textSelection(.enabled)
                Text(edit.before == nil ? "New" : edit.after == nil ? "Deleted" : "Modified")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(expanded.contains(edit.id) ? "Hide diff" : "Show diff") {
                    if expanded.contains(edit.id) { expanded.remove(edit.id) } else { expanded.insert(edit.id) }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            if expanded.contains(edit.id) {
                DiffView(proposal: edit, compact: true)
            }
        }
        .padding(LumenStyle.space2)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { approved.contains(id) }, set: { on in
            var ids = approved
            if on { ids.insert(id) } else { ids.remove(id) }
            approved = ids
        })
    }
}

/// A sheet listing every applied change with the ability to inspect and undo.
struct ChangesView: View {
    @Bindable var chat: ChatModel
    var initialSelection: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project Changes").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            }
            .padding(LumenStyle.space4)
            Divider()
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(chat.changes) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.proposal.path).lineLimit(2)
                            Text(change.undone ? "Undone" : "Applied").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(change.id)
                    }
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                if let change = chat.changes.first(where: { $0.id == selectedID }) {
                    VStack(spacing: LumenStyle.space3) {
                        DiffView(proposal: change.proposal)
                        HStack {
                            Text("Recovery: \(change.backupPath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            Button(chat.isUndoing ? "Undoing…" : "Undo This Change") { Task { await chat.undoChange(change.id) } }
                                .disabled(chat.isBusy || change.undone)
                        }
                        .padding(.horizontal, LumenStyle.space4)
                        if let error = chat.error {
                            NoteView(message: error) { chat.error = nil }
                                .padding(.horizontal, LumenStyle.space4)
                        }
                    }
                    .padding(.vertical, LumenStyle.space4)
                } else {
                    ContentUnavailableView("Select a change", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 560, idealHeight: 680)
        .onAppear { selectedID = initialSelection ?? chat.changes.last?.id }
    }
}
