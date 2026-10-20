import AppKit
import LumenCore
import SwiftUI
import UniformTypeIdentifiers

/// The message composer: a standard bordered input with native menu controls
/// for the provider, model, and reasoning effort.
struct Composer: View {
    @Bindable var chat: ChatModel
    @FocusState.Binding var focused: Bool
    var openInspector: (InspectorTab) -> Void
    @State private var showingModels = false
    @State private var imageError: String?

    private var placeholder: String {
        if chat.workspace == nil { return "Message Lumen…" }
        return chat.isPlanMode ? "Describe what you want planned…" : "What would you like to work on?"
    }

    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachedImages.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LumenStyle.space2) {
            if !chat.attachments.isEmpty { attachments }
            if !chat.attachedImages.isEmpty { imageAttachments }
            input
            footer
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LumenStyle.space6)
        .padding(.top, LumenStyle.space2)
        .padding(.bottom, LumenStyle.space4)
    }

    private var imageAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LumenStyle.space2) {
                ForEach(Array(chat.attachedImages.enumerated()), id: \.offset) { _, image in
                    ZStack(alignment: .topTrailing) {
                        if let nsImage = NSImage(data: image.data) {
                            Image(nsImage: nsImage)
                                .resizable().scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous)
                                .fill(.quaternary).frame(width: 64, height: 64)
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        }
                        Button { chat.detachImage(image) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .accessibilityLabel("Remove image")
                    }
                }
            }
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LumenStyle.space2) {
                ForEach(chat.attachments, id: \.self) { path in
                    HStack(spacing: LumenStyle.space1) {
                        Image(systemName: "paperclip").font(.caption)
                        Text(path).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button { chat.detach(path) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(path)")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LumenStyle.space2).padding(.vertical, LumenStyle.space1)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var input: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(2)
                .lineLimit(1...10)
                .focused($focused)
                .accessibilityLabel("Message")
                .padding(LumenStyle.space3)
                .onPasteCommand(of: [.image, .png, .tiff]) { _ in pasteFromPasteboard() }
            Divider()
            HStack(spacing: LumenStyle.space3) {
                Button { openInspector(.files) } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach a file")
                    .accessibilityLabel("Attach a file")
                providerMenu
                modelMenu
                reasoningMenu
                planButton
                Spacer(minLength: 0)
                sendButton
            }
            .padding(.horizontal, LumenStyle.space3)
            .padding(.vertical, LumenStyle.space2)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: LumenStyle.radiusMedium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LumenStyle.radiusMedium, style: .continuous)
            .strokeBorder(focused ? Color.accentColor : LumenStyle.separator, lineWidth: 1))
    }

    @ViewBuilder private var sendButton: some View {
        if chat.isRunning {
            Button { chat.stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.bordered).buttonBorderShape(.circle)
                .accessibilityLabel("Stop response").keyboardShortcut(.escape, modifiers: []).help("Stop · Esc")
        } else {
            Button { chat.send() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .accessibilityLabel("Send message").keyboardShortcut(.return, modifiers: .command)
                .disabled(chat.isBusy || !canSend || chat.selectedProfile == nil || chat.model.isEmpty)
        }
    }

    private var footer: some View {
        HStack(spacing: LumenStyle.space3) {
            if let imageError {
                NoteView(kind: .error, size: .compact, message: imageError)
            } else if chat.selectedProfile?.kind == .chatGPT {
                Text("Using ChatGPT plan").font(.caption).foregroundStyle(.secondary)
                Link("Manage usage", destination: ChatGPTAuthorization.usageURL).font(.caption)
            } else {
                Text("⌘ Return to send · Esc to stop").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if chat.isCompacting {
                Text("Summarizing older turns…").font(.caption).foregroundStyle(.secondary)
            } else if chat.contextTokens > 0 {
                let used = chat.contextTokens.formatted(.number.notation(.compactName))
                let limit = chat.contextLimit.formatted(.number.notation(.compactName))
                Text("Context ≈ \(used) / \(limit)\(chat.isContextCompacted ? " · summarized" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(chat.isContextCompacted
                        ? "Older turns are replaced by a summary for the model; the transcript keeps them."
                        : "Estimated size of the next request")
            }
            if let usage = chat.usage {
                Text("\(usage.inputTokens) in · \(usage.outputTokens) out").font(.caption).foregroundStyle(.secondary)
            }
            if let rate = chat.tokensPerSecond {
                Text("\(rate, format: .number.precision(.fractionLength(1))) tok/s")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Output tokens per second for the last response")
            }
            if let cost = chat.estimatedCost {
                Text(cost, format: .currency(code: "USD")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Reads an image from the pasteboard — copied pixels or copied image files —
    /// and attaches it to the next turn. Non-image pastes fall through to the field.
    private func pasteFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard), let attachment = Self.attachment(from: image) {
            chat.attachImage(attachment)
            imageError = nil
            return
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = urls.compactMap { url -> ImageAttachment? in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let data = try? Data(contentsOf: url) else { return nil }
            return ImageAttachment(mediaType: type.preferredMIMEType ?? "application/octet-stream", data: data)
        }
        guard !images.isEmpty else { return }
        images.forEach(chat.attachImage)
        imageError = nil
    }

    /// Normalizes any pasted image to PNG so every provider receives a format it accepts.
    private static func attachment(from image: NSImage) -> ImageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return ImageAttachment(mediaType: "image/png", data: png)
    }

    private var providerMenu: some View {
        Menu {
            Button("No provider") { chat.selectedProfileID = nil }
            ForEach(chat.profiles) { profile in
                Button { chat.selectedProfileID = profile.id } label: {
                    if chat.selectedProfileID == profile.id { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
            }
        } label: {
            Label(chat.selectedProfile?.name ?? "Provider", systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Provider")
        .help(chat.selectedProfile?.name ?? "Choose a provider in Settings")
    }

    private var selectedModelName: String {
        guard !chat.model.isEmpty else { return "Choose Model" }
        return chat.modelInfo.first { $0.id == chat.model }?.label ?? chat.model
    }

    private var modelMenu: some View {
        Button { showingModels = true } label: {
            HStack(spacing: LumenStyle.space1) {
                Image(systemName: "cpu")
                Text(selectedModelName).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Model")
        .help(chat.model.isEmpty ? "Choose a model or enter its ID" : "\(selectedModelName) · \(chat.model)")
        .popover(isPresented: $showingModels, arrowEdge: .bottom) {
            ModelPicker(models: chat.modelInfo, selected: chat.model, isLoading: chat.isLoadingModels,
                        select: { chat.model = $0; showingModels = false },
                        refresh: { await chat.loadModels() })
        }
    }

    private var planButton: some View {
        Button { chat.setPlanMode(!chat.isPlanMode) } label: {
            Label(chat.isPlanMode ? "Planning" : "Plan", systemImage: "checklist")
                .foregroundStyle(chat.isPlanMode ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(chat.isBusy || chat.workspace == nil)
        .accessibilityLabel(chat.isPlanMode ? "Turn off plan mode" : "Turn on plan mode")
        .help(chat.isPlanMode
              ? "Plan mode is read-only: Lumen explores and writes a checklist; edits and commands are disabled."
              : "Plan first: explore the project read-only, then build from a checklist.")
    }

    private var reasoningMenu: some View {
        Menu {
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Button { chat.reasoning = effort } label: {
                    if chat.reasoning == effort { Label(effort.title, systemImage: "checkmark") }
                    else { Text(effort.title) }
                }
            }
        } label: {
            Label(chat.reasoning.title, systemImage: "brain")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Reasoning effort")
        .help("Reasoning: \(chat.reasoning.title). Default lets the provider choose; other efforts need model support.")
    }
}
