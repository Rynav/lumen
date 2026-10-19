import AppKit
import LumenCore
import SwiftUI

@main
struct LumenApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var chat = ChatModel()

    var body: some Scene {
        Window("Lumen", id: "main") {
            RootView(chat: chat)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { chat.newConversation() }
                    .keyboardShortcut("n")
                    .disabled(chat.isBusy)
                Button("Open Project…") { openProject() }
                    .keyboardShortcut("o")
                    .disabled(chat.isBusy)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: "settings") }
                    .keyboardShortcut(",")
            }
        }

        // A plain Window (rather than the Settings scene) is what makes the
        // window resizable; contentMinSize keeps it from shrinking past the form.
        Window("Settings", id: "settings") {
            SettingsView(profiles: $chat.profiles, systemPrompt: $chat.systemPrompt,
                          maxIterations: $chat.maxIterations, reasoning: $chat.reasoning,
                          approvalPolicy: $chat.approvalPolicy, mcpServers: $chat.mcpServers,
                          testConnection: ChatModel.testConnection, stopRequests: { chat.stop() })
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
    }

    @MainActor private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { chat.openWorkspace(url) }
    }
}
