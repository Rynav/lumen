import LumenCore
import SwiftUI

@main
struct LumenApp: App {
    @State private var profiles: [ProviderProfile] = []
    @State private var systemPrompt = "You are a helpful coding agent. Inspect the workspace before changing files."
    @State private var maxIterations = 25

    var body: some Scene {
        Window("Lumen", id: "main") {
            NavigationSplitView {
                List { Label("Workspaces", systemImage: "folder") }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } detail: {
                ContentUnavailableView("Lumen", systemImage: "sparkle", description: Text("Add a provider in Settings to get started."))
            }
            .frame(minWidth: 820, minHeight: 560)
        }
        Settings {
            SettingsView(profiles: $profiles, systemPrompt: $systemPrompt, maxIterations: $maxIterations)
        }
    }
}
