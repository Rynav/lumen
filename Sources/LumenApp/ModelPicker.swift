import LumenCore
import SwiftUI

/// The composer's model list: searchable, named, and honest about free models.
/// Cataloguing providers (OpenCode Console) supply names and prices; everything
/// else falls back to the raw id.
struct ModelPicker: View {
    let models: [ModelInfo]
    let selected: String
    let isLoading: Bool
    var select: (String) -> Void
    var refresh: () async -> Void

    @State private var query = ""
    @State private var custom = ""
    @FocusState private var searching: Bool

    private var filtered: [ModelInfo] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(term)
                || ($0.name?.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LumenStyle.space2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .accessibilityLabel("Search models")
            }
            .padding(LumenStyle.space3)
            Divider()
            list
            Divider()
            customRow
            refreshRow
        }
        .frame(width: 340)
        .onAppear { searching = true }
    }

    @ViewBuilder private var list: some View {
        if filtered.isEmpty {
            Text(models.isEmpty ? "No models loaded." : "No model matches “\(query)”.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(LumenStyle.space5)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { model in
                        ModelRow(model: model, isSelected: model.id == selected) { select(model.id) }
                    }
                }
                .padding(LumenStyle.space1)
            }
            .frame(height: 300)
        }
    }

    private var customRow: some View {
        HStack(spacing: LumenStyle.space2) {
            TextField("Use a custom model ID", text: $custom)
                .textFieldStyle(.roundedBorder)
                .onSubmit(useCustom)
                .accessibilityLabel("Custom model ID")
            Button("Use", action: useCustom)
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, LumenStyle.space3)
        .padding(.top, LumenStyle.space2)
    }

    private var refreshRow: some View {
        HStack(spacing: LumenStyle.space2) {
            Button(isLoading ? "Refreshing…" : "Refresh Models") { Task { await refresh() } }
                .buttonStyle(.borderless)
                .disabled(isLoading)
            Spacer(minLength: 0)
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, LumenStyle.space3)
        .padding(.vertical, LumenStyle.space2)
    }

    private func useCustom() {
        let id = custom.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        select(id)
    }
}

private struct ModelRow: View {
    let model: ModelInfo
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            select()
        } label: {
            HStack(spacing: LumenStyle.space2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label).lineLimit(1)
                    if model.label != model.id {
                        Text(model.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: LumenStyle.space2)
                if model.isFree { freeBadge }
                if isSelected {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, LumenStyle.space2)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: LumenStyle.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var freeBadge: some View {
        Text("Free")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LumenStyle.success.opacity(0.15), in: Capsule())
            .foregroundStyle(LumenStyle.success)
    }
}
