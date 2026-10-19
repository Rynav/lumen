import Foundation

public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph, heading(Int), listItem(String), quote, code(String)
    }
    public let id: Int
    public let kind: Kind
    public let text: String

    public static func parse(_ text: String) -> [Self] {
        var blocks: [Self] = []
        var lines: [String] = []
        var language: String?
        func append(_ kind: Kind, _ text: String) {
            blocks.append(Self(id: blocks.count, kind: kind, text: text))
        }
        func flush() {
            guard !lines.isEmpty else { return }
            append(language.map(Kind.code) ?? .paragraph, lines.joined(separator: "\n"))
            lines = []
        }
        // ponytail: native Markdown for inline styles, a small block parser for layout; use a full parser if tables/nested lists are needed.
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                language = language == nil ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
            } else if language != nil {
                lines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let digits = line.prefix(while: { $0.isNumber }).count
                if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                    flush(); append(.heading(hashes), String(line.dropFirst(hashes + 1)))
                } else if ["- ", "* ", "+ "].contains(where: { line.hasPrefix($0) }) {
                    flush(); append(.listItem("•"), String(line.dropFirst(2)))
                } else if digits > 0, line.dropFirst(digits).hasPrefix(". ") {
                    flush(); append(.listItem(String(line.prefix(digits)) + "."), String(line.dropFirst(digits + 2)))
                } else if line.hasPrefix("> ") {
                    flush(); append(.quote, String(line.dropFirst(2)))
                } else { lines.append(line) }
            }
        }
        flush()
        return blocks
    }
}
