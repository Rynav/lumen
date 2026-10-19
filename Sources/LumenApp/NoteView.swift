import SwiftUI

/// One look for inline notes — failures, warnings, hints — so the same kind of
/// message reads the same in the transcript, the inspectors and the composer.
struct NoteView: View {
    enum Kind {
        case error, warning, info

        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .warning: "exclamationmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: LumenStyle.danger
            case .warning: LumenStyle.warning
            case .info: .accentColor
            }
        }
    }

    /// `full` is the tinted card with a dismiss button; `compact` fits a list row
    /// or a panel without pushing the content around.
    enum Size { case full, compact }

    var kind: Kind = .error
    var size: Size = .full
    var title: String?
    var message: String
    var dismiss: (() -> Void)?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size == .compact ? LumenStyle.radiusSmall : LumenStyle.radiusMedium,
                         style: .continuous)
    }

    var body: some View {
        HStack(alignment: .top, spacing: size == .compact ? LumenStyle.space2 : LumenStyle.space3) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                if size == .full, let title {
                    Text(title).font(.callout.weight(.semibold))
                }
                Text(message)
                    .font(size == .compact ? .caption : .callout)
                    .foregroundStyle(size == .compact || title != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if size == .full, let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(size == .compact ? LumenStyle.space2 : LumenStyle.space3)
        .background(shape.fill(kind.tint.opacity(size == .compact ? 0.08 : 0.10)))
        .overlay {
            if size == .full { shape.strokeBorder(kind.tint.opacity(0.35), lineWidth: 1) }
        }
    }

    private var icon: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size == .compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(size == .compact ? AnyShapeStyle(kind.tint) : AnyShapeStyle(.white))
            .frame(width: size == .compact ? nil : 20, height: size == .compact ? nil : 20)
            .background { if size == .full { Circle().fill(kind.tint) } }
            .accessibilityHidden(true)
    }
}
