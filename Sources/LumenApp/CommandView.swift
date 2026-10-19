import AppKit
import LumenCore
import SwiftUI

/// A card that asks the user to approve a command before it runs.
struct CommandApprovalView: View {
    let proposal: CommandProposal
    let decide: (Bool) -> Void
    let stop: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: LumenStyle.space3) {
                Text("This runs project code with your macOS user permissions. It can modify files, access the network, and read files outside the project. Commands are not sandboxed, and their side effects cannot automatically be undone.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: LumenStyle.space2) {
                    Text(proposal.executable).font(.system(.body, design: .monospaced).weight(.semibold))
                    if proposal.arguments.isEmpty {
                        Text("No arguments").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(proposal.arguments.enumerated()), id: \.offset) { index, argument in
                            HStack(alignment: .top, spacing: LumenStyle.space2) {
                                Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
                                Text(argument.isEmpty ? "(empty argument)" : argument).textSelection(.enabled)
                            }
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LumenStyle.space3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))

                Label(proposal.directory, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Timeout: \(proposal.timeoutSeconds)s · stdin closed · environment scrubbed · output limited to head/tail")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack {
                    Button("Stop Agent") { stop() }.buttonStyle(.borderless)
                    Spacer()
                    Button("Reject") { decide(false) }.keyboardShortcut(.escape, modifiers: [])
                    Button("Approve & Run") { decide(true) }.buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, LumenStyle.space1)
        } label: {
            Label("Review command", systemImage: "terminal")
        }
    }
}

struct CommandConsoleView: View {
    let command: CommandUpdate
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TerminalTextView(text: command.output.isEmpty ? "Waiting for output…" : command.output)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
                .padding(.top, LumenStyle.space1)
            if let error = command.error {
                NoteView(kind: .error, size: .compact, message: error)
                    .padding(.top, LumenStyle.space1)
            }
            if let result = command.result {
                Text("\(result.totalBytes) output bytes\(result.truncated ? " · truncated (head/tail)" : "")")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, LumenStyle.space1)
            }
        } label: {
            HStack(spacing: LumenStyle.space2) {
                Label(command.proposal.executable, systemImage: "terminal").font(.system(.callout, design: .monospaced))
                Spacer(minLength: 0)
                if command.isRunning { ProgressView().controlSize(.mini) }
                Text(status).font(.caption.weight(.medium)).foregroundStyle(statusColor)
            }
        }
        .padding(LumenStyle.space2)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
    }

    private var status: String {
        if command.error != nil { return "Failed to run" }
        guard let result = command.result else { return "Running" }
        if result.timedOut { return "Timed out" }
        if result.cancelled { return "Stopped" }
        return "Exit \(result.exitCode)"
    }

    private var statusColor: Color {
        if command.isRunning { return .secondary }
        return command.result?.succeeded == true ? LumenStyle.success : LumenStyle.warning
    }
}

/// Plain selectable AppKit text, not a terminal emulator or an executable escape-sequence surface.
private struct TerminalTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize; view.textContainer?.widthTracksTextView = false
        view.setAccessibilityLabel("Command output")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let followsOutput = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 80
        view.string = text
        if followsOutput { view.scrollToEndOfDocument(nil) }
    }
}
