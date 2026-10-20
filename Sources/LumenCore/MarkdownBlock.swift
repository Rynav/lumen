import Foundation

public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph, heading(Int), listItem(String), quote, code(String)
        case table(header: [String], rows: [[String]])
    }
    public let id: Int
    public let kind: Kind
    public let text: String

    public static func parse(_ text: String) -> [Self] {
        let source = text.components(separatedBy: "\n")
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
        // ponytail: native Markdown for inline styles, a small block parser for layout; use a full parser if nested lists are needed.
        var index = 0
        while index < source.count {
            let line = source[index]
            if line.hasPrefix("```") {
                flush()
                language = language == nil ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
            } else if language != nil {
                lines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if let table = table(at: index, in: source) {
                flush()
                append(.table(header: table.header, rows: table.rows), "")
                index = table.end - 1
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
            index += 1
        }
        flush()
        return blocks
    }

    /// A GitHub-style table: a header row followed by a delimiter row, then body rows.
    private static func table(at index: Int, in lines: [String]) -> (header: [String], rows: [[String]], end: Int)? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let header = cells(in: lines[index])
        let delimiter = cells(in: lines[index + 1])
        guard !header.isEmpty, delimiter.count == header.count,
              delimiter.allSatisfy(isDelimiter) else { return nil }
        var rows: [[String]] = []
        var end = index + 2
        while end < lines.count {
            let line = lines[end]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, line.contains("|") else { break }
            let row = cells(in: line)
            guard !row.isEmpty else { break }
            rows.append(Array(row.prefix(header.count))
                + Array(repeating: "", count: max(0, header.count - row.count)))
            end += 1
        }
        return (header, rows, end)
    }

    /// Splits a row on unescaped pipes, dropping the optional leading/trailing ones.
    private static func cells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var values: [String] = []
        var value = ""
        var escaped = false
        var endedWithSeparator = false
        for character in trimmed {
            if escaped {
                value.append(character)
                escaped = false
                endedWithSeparator = false
            } else if character == "\\" {
                value.append(character)
                escaped = true
                endedWithSeparator = false
            } else if character == "|" {
                values.append(value)
                value = ""
                endedWithSeparator = true
            } else {
                value.append(character)
                endedWithSeparator = false
            }
        }
        values.append(value)
        if endedWithSeparator, !values.isEmpty { values.removeLast() }
        if trimmed.hasPrefix("|"), !values.isEmpty { values.removeFirst() }
        return values.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDelimiter(_ cell: String) -> Bool {
        var text = Substring(cell.trimmingCharacters(in: .whitespaces))
        if text.first == ":" { text = text.dropFirst() }
        if text.last == ":" { text = text.dropLast() }
        return !text.isEmpty && text.allSatisfy { $0 == "-" }
    }
}
