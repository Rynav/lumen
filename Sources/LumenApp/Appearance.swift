import AppKit
import LumenCore
import SwiftUI

/// Shared spacing and the few semantic colors not covered by system styles.
/// Everything else uses standard macOS materials, controls, and the user's
/// system accent color.
enum LumenStyle {
    // 4pt grid
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24

    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 14

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let separator = Color(nsColor: .separatorColor)

    /// One shared mapping for tool symbols so the transcript and the inspector agree.
    static func toolSymbol(_ toolName: String) -> String {
        switch toolName {
        case "read_file": "doc.text"
        case "search_files": "magnifyingglass"
        case "list_files": "folder"
        case "edit_file": "square.and.pencil"
        case "run_command": "terminal"
        default: toolName.hasPrefix("mcp__") ? "wrench.and.screwdriver" : "checklist"
        }
    }

    static func statusSymbol(_ status: AgentAction.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .review: "hand.raised"
        case .declined, .stopped: "minus.circle"
        case .queued, .running: "clock"
        }
    }

    static func statusColor(_ status: AgentAction.Status) -> Color {
        switch status {
        case .completed: success
        case .failed: danger
        case .review: warning
        default: .secondary
        }
    }
}
