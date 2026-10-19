import LumenCore
import SwiftUI
import UniformTypeIdentifiers

/// The window shell: a native sidebar, the conversation detail, and a native
/// inspector for the workspace. Uses standard macOS navigation and toolbar.
struct RootView: View {
    @Bindable var chat: ChatModel
    @State private var selection: SidebarItem?
    @State private var showingInspector = true
    @State private var inspectorTab: InspectorTab = .activity
    @State private var choosingProject = false
    @State private var deleting: SidebarItem?
    @FocusState private var composerFocused: Bool

    private var conversationTitle: String {
        chat.conversations.first { $0.id == chat.currentConversationID }?.title ?? "New chat"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            ConversationView(chat: chat, composerFocused: $composerFocused,
                             chooseProject: { choosingProject = true },
                             openInspector: { tab in inspectorTab = tab; showingInspector = true })
                .navigationTitle(conversationTitle)
        }
        .inspector(isPresented: $showingInspector) {
            InspectorView(chat: chat, tab: $inspectorTab)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 560)
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $choosingProject, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): chat.openWorkspace(url)
            case .failure(let error): chat.error = error.localizedDescription
            }
        }
        .onAppear { selection = .conversation(chat.currentConversationID) }
        .onChange(of: selection) { _, item in
            switch item {
            case .project(let path): chat.openWorkspace(URL(fileURLWithPath: path))
            case .conversation(let id): if id != chat.currentConversationID { chat.selectConversation(id) }
            case nil: break
            }
        }
        .onChange(of: chat.currentConversationID) { _, id in
            selection = .conversation(id)
            composerFocused = true
        }
        .onChange(of: chat.pendingEdit?.id) { _, id in
            if id != nil { inspectorTab = .changes; showingInspector = true }
        }
        .onChange(of: chat.pendingEditBatch?.id) { _, id in
            if id != nil { inspectorTab = .changes; showingInspector = true }
        }
        .onChange(of: chat.pendingCommand?.id) { _, id in
            if id != nil { inspectorTab = .activity; showingInspector = true }
        }
        .onChange(of: chat.profiles) { _, profiles in
            if !profiles.contains(where: { $0.id == chat.selectedProfileID }) {
                chat.selectedProfileID = profiles.first?.id
            }
        }
        .task { if chat.selectedProfile != nil { await chat.loadModels() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Projects") {
                if chat.projectPaths.isEmpty {
                    Button { choosingProject = true } label: {
                        Label("Open a Project…", systemImage: "folder.badge.plus")
                    }
                    .disabled(chat.isBusy)
                } else {
                    ForEach(chat.projectPaths, id: \.self) { path in
                        projectRow(path)
                    }
                }
            }

            let projectChats = chat.workspace == nil
                ? [] : chat.conversations.filter { $0.projectPath == chat.workspace?.root.path }
            if !projectChats.isEmpty {
                Section("Conversations") {
                    ForEach(projectChats) { conversation in
                        conversationRow(conversation)
                    }
                }
            }

            let standalone = chat.conversations.filter { $0.projectPath == nil }
            if !standalone.isEmpty {
                Section("Chats") {
                    ForEach(standalone) { conversation in
                        conversationRow(conversation)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(deleting.map { title(for: $0) } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { item in
            switch item {
            case .conversation(let id):
                Button("Delete Chat", role: .destructive) { chat.deleteConversation(id); deleting = nil }
            case .project(let path):
                Button("Remove Project and Chats", role: .destructive) { chat.removeProject(path); deleting = nil }
            }
        } message: { item in
            switch item {
            case .conversation:
                Text("This deletes the chat's messages from Lumen. Files on disk are untouched.")
            case .project:
                Text("This removes the project and deletes its saved chats from Lumen. Files on disk are untouched.")
            }
        }
    }

    private func title(for item: SidebarItem) -> String {
        switch item {
        case .project(let path): URL(fileURLWithPath: path).lastPathComponent
        case .conversation(let id): chat.conversations.first { $0.id == id }?.title ?? "Chat"
        }
    }

    private func conversationRow(_ conversation: ChatConversation) -> some View {
        Label(conversation.title, systemImage: "bubble.left")
            .tag(SidebarItem.conversation(conversation.id))
            .contextMenu {
                Button("Delete Chat", role: .destructive) {
                    deleting = .conversation(conversation.id)
                }
                .disabled(chat.isBusy)
            }
    }

    private func projectRow(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let isOpen = chat.workspace?.root.path == path
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } icon: {
            Image(systemName: isOpen ? "folder.fill" : "folder")
        }
        .tag(SidebarItem.project(path))
        .help(path)
        .contextMenu {
            Button("Remove Project", role: .destructive) { deleting = .project(path) }
                .disabled(chat.isBusy)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Open Project", systemImage: "folder.badge.plus") { choosingProject = true }
                .disabled(chat.isBusy)
                .help("Open a project (⌘O)")
        }
        ToolbarItem {
            if chat.isAwaitingApproval {
                Button("Review", systemImage: "hand.raised.fill") {
                    inspectorTab = chat.pendingEdit != nil || chat.pendingEditBatch != nil ? .changes : .activity
                    showingInspector = true
                }
                .help("Review the proposed action")
            }
        }
        ToolbarItem {
            if chat.isRunning { ProgressView().controlSize(.small) }
        }
        ToolbarItem {
            Button("New Conversation", systemImage: "square.and.pencil") {
                chat.newConversation(); composerFocused = true
            }
            .disabled(chat.isBusy)
            .help("New conversation (⌘N)")
        }
        ToolbarItem {
            Button("Toggle Inspector", systemImage: "sidebar.right") { showingInspector.toggle() }
                .help("Show or hide the inspector (⌘⌥I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

private enum SidebarItem: Hashable {
    case project(String)
    case conversation(UUID)
}
