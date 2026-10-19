import LumenCore
import SwiftUI

/// A read-only project explorer. Selecting a file opens a preview that can be
/// attached to the next prompt.
struct FileTreeView: View {
    let workspace: WorkspaceService
    let revision: Int
    let busy: Bool
    var onAttach: (String) -> Void = { _ in }
    @State private var refresh = 0
    @State private var preview: WorkspaceEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Explorer").font(.subheadline.weight(.semibold))
                    .help("Git internals, recovery/build folders and symlinks are hidden.")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Refresh file tree")
            }
            .padding(.bottom, LumenStyle.space2)
            ScrollView {
                FileTreeFolder(workspace: workspace, path: ".", revision: revision + refresh, preview: $preview, onAttach: onAttach)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(busy)
        .sheet(item: $preview) { entry in FilePreviewView(workspace: workspace, entry: entry, onAttach: onAttach) }
    }
}

private struct FileTreeFolder: View {
    let workspace: WorkspaceService
    let path: String
    let revision: Int
    @Binding var preview: WorkspaceEntry?
    let onAttach: (String) -> Void
    @State private var entries: [WorkspaceEntry] = []
    @State private var error: String?
    @State private var truncated = false
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if loading { ProgressView().controlSize(.small) }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    FileTreeBranch(workspace: workspace, entry: entry, revision: revision, preview: $preview, onAttach: onAttach)
                } else {
                    Button { preview = entry } label: {
                        Label(entry.name, systemImage: "doc.text")
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3).padding(.horizontal, LumenStyle.space2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(entry.path).accessibilityLabel("Preview \(entry.path)")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(LumenStyle.danger) }
            if truncated { Text("Folder listing limited to 500 entries.").font(.caption).foregroundStyle(.secondary) }
            if !loading, entries.isEmpty, error == nil {
                Text("Empty folder").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: revision) {
            loading = true
            defer { loading = false }
            do {
                let listing = try await workspace.directoryEntries(path: path)
                entries = listing.entries; truncated = listing.truncated; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct FileTreeBranch: View {
    let workspace: WorkspaceService
    let entry: WorkspaceEntry
    let revision: Int
    @Binding var preview: WorkspaceEntry?
    let onAttach: (String) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                FileTreeFolder(workspace: workspace, path: entry.path, revision: revision, preview: $preview, onAttach: onAttach)
                    .padding(.leading, LumenStyle.space3)
            }
        } label: {
            Label(entry.name, systemImage: expanded ? "folder.fill" : "folder")
                .font(.callout).lineLimit(1)
                .padding(.vertical, 3).help(entry.path)
        }
    }
}

private struct FilePreviewView: View {
    let workspace: WorkspaceService
    let entry: WorkspaceEntry
    let onAttach: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space3) {
            HStack(spacing: LumenStyle.space2) {
                Label(entry.path, systemImage: "doc.text").font(.headline).textSelection(.enabled)
                Spacer()
                Button("Attach to Prompt", systemImage: "paperclip") {
                    onAttach(entry.path)
                    dismiss()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            }
            ScrollView([.vertical, .horizontal]) {
                Text(content).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(LumenStyle.space3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous).strokeBorder(LumenStyle.separator))
            Text("Read-only preview · first 500 lines, up to 24,000 characters").font(.caption).foregroundStyle(.secondary)
        }
        .padding(LumenStyle.space5)
        .frame(minWidth: 720, minHeight: 520)
        .task {
            do { content = try await workspace.readFile(path: entry.path, limit: 500) }
            catch { content = error.localizedDescription }
        }
    }
}
