import Foundation

/// A Markdown prompt template from `~/.lumen/commands`. The file name is the
/// slash command; the body is inserted into the composer or expanded on send.
public struct CustomCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// The first non-empty line, without Markdown heading marks, for the menu.
    public var summary: String {
        let first = text.split(whereSeparator: \.isNewline)
            .first { !String($0).trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first else { return "" }
        let line = String(first).trimmingCharacters(in: .whitespaces)
        let text = line.drop(while: { $0 == "#" })
        return String(String(text).trimmingCharacters(in: .whitespaces).prefix(120))
    }
}

/// Reads the user's command folder with the same app-file loader as the global
/// instruction file. A broken or oddly named file is skipped, never fatal.
public enum CustomCommands {
    public static let directoryName = "commands"
    static let maximumBytes = 65_536

    public static func load(from directory: URL) -> [CustomCommand] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(100)
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
                let data = (try? WorkspaceService.loadAppFile(named: url.lastPathComponent, in: directory)) ?? nil
                guard let data, data.count <= maximumBytes,
                      let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return CustomCommand(name: name, text: text)
            }
    }
}
