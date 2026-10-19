import Foundation

struct PatchHunk: Equatable, Sendable {
    var oldLines: [String] = []
    var newLines: [String] = []
}

/// A parsed file operation. Applying it produces the complete new file text,
/// which then goes through the same proposal, snapshot and atomic-write path as
/// a single `edit_file`.
enum FilePatch: Equatable, Sendable {
    case add(path: String, lines: [String])
    case update(path: String, hunks: [PatchHunk])
    case delete(path: String)

    var path: String {
        switch self {
        case .add(let path, _), .update(let path, _), .delete(let path): path
        }
    }

    func applying(to before: String?) throws -> String? {
        switch self {
        case .add(let path, let lines):
            guard before == nil else { throw WorkspaceError.patch("Add File \(path): the file already exists.") }
            guard !lines.isEmpty else { throw WorkspaceError.patch("Add File \(path): add at least one line.") }
            return lines.joined(separator: "\n") + "\n"
        case .delete(let path):
            guard before != nil else { throw WorkspaceError.patch("Delete File \(path): the file does not exist.") }
            return nil
        case .update(let path, let hunks):
            guard let before else { throw WorkspaceError.patch("Update File \(path): the file does not exist.") }
            guard !before.utf8.contains(0x0D) else {
                throw WorkspaceError.patch("Update File \(path): the file uses CR or CRLF line endings, which apply_patch does not support yet. Convert it to LF before patching.")
            }
            if before.isEmpty, hunks.count == 1, let hunk = hunks.first, hunk.oldLines.isEmpty {
                return hunk.newLines.joined(separator: "\n") + "\n"
            }
            var lines = before.components(separatedBy: "\n")
            for hunk in hunks {
                guard !hunk.oldLines.isEmpty else {
                    throw WorkspaceError.patch("Update File \(path): each hunk needs at least one context line or removed line. Pure additions are only supported for an empty file.")
                }
                var match: Int?
                if hunk.oldLines.count <= lines.count {
                    for start in 0...(lines.count - hunk.oldLines.count)
                    where lines[start..<(start + hunk.oldLines.count)].elementsEqual(hunk.oldLines) {
                        guard match == nil else {
                            throw WorkspaceError.patch("Update File \(path): the hunk context matches more than once. Add more surrounding context. First line: \(hunk.oldLines[0])")
                        }
                        match = start
                    }
                }
                guard let start = match else {
                    throw WorkspaceError.patch("Update File \(path): the hunk context does not match the current file. Read the file and use its exact text.")
                }
                lines.replaceSubrange(start..<(start + hunk.oldLines.count), with: hunk.newLines)
            }
            return lines.joined(separator: "\n")
        }
    }
}

enum PatchParser {
    static func parse(_ text: String) throws -> [FilePatch] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        guard index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "*** Begin Patch" else {
            throw WorkspaceError.patch("Start the patch with *** Begin Patch.")
        }
        index += 1

        var patches: [FilePatch] = []
        var seen: Set<String> = []
        var ended = false
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed == "*** End Patch" { ended = true; index += 1; break }
            guard patches.count < maxFiles else {
                throw WorkspaceError.patch("A patch may change at most \(maxFiles) files.")
            }

            if let path = value(after: "*** Update File:", in: trimmed) {
                try remember(path, in: &seen)
                index += 1
                var hunks: [PatchHunk] = []
                var current: PatchHunk?
                while index < lines.count, !lines[index].hasPrefix("*** ") {
                    let line = lines[index]
                    if line.hasPrefix("@@") {
                        if let current { hunks.append(current) }
                        current = PatchHunk()
                    } else {
                        if current == nil { current = PatchHunk() }
                        switch line.first {
                        case " ":
                            let text = String(line.dropFirst())
                            current?.oldLines.append(text)
                            current?.newLines.append(text)
                        case "-": current?.oldLines.append(String(line.dropFirst()))
                        case "+": current?.newLines.append(String(line.dropFirst()))
                        default:
                            throw WorkspaceError.patch("Update File \(path), line \(index + 1): diff lines must start with a space, +, or -. Use a single space for an unchanged blank line.")
                        }
                    }
                    index += 1
                }
                if let current { hunks.append(current) }
                guard !hunks.isEmpty else { throw WorkspaceError.patch("Update File \(path): add a hunk starting with @@.") }
                guard hunks.count <= maxHunksPerFile else {
                    throw WorkspaceError.patch("Update File \(path): a file may have at most \(maxHunksPerFile) hunks.")
                }
                for hunk in hunks {
                    guard hunk.oldLines != hunk.newLines else {
                        throw WorkspaceError.patch("Update File \(path): the hunk does not change anything.")
                    }
                }
                patches.append(.update(path: path, hunks: hunks))
            } else if let path = value(after: "*** Add File:", in: trimmed) {
                try remember(path, in: &seen)
                index += 1
                var content: [String] = []
                while index < lines.count, !lines[index].hasPrefix("*** ") {
                    let line = lines[index]
                    if line.hasPrefix("+") { content.append(String(line.dropFirst())) }
                    else { throw WorkspaceError.patch("Add File \(path), line \(index + 1): content lines must start with +.") }
                    index += 1
                }
                guard !content.isEmpty else { throw WorkspaceError.patch("Add File \(path): add at least one line.") }
                patches.append(.add(path: path, lines: content))
            } else if let path = value(after: "*** Delete File:", in: trimmed) {
                try remember(path, in: &seen)
                index += 1
                patches.append(.delete(path: path))
            } else {
                throw WorkspaceError.patch("Unknown patch directive on line \(index + 1): \(trimmed.prefix(60))")
            }
        }

        guard ended else { throw WorkspaceError.patch("End the patch with *** End Patch.") }
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        guard index == lines.count else { throw WorkspaceError.patch("Unexpected content after *** End Patch.") }
        guard !patches.isEmpty else { throw WorkspaceError.patch("The patch contains no file changes.") }
        return patches
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func remember(_ path: String, in seen: inout Set<String>) throws {
        guard !path.isEmpty else { throw WorkspaceError.patch("A file directive is missing its path.") }
        guard seen.insert(path).inserted else {
            throw WorkspaceError.patch("Each file may appear only once in a patch: \(path).")
        }
    }

    private static let maxFiles = 32
    private static let maxHunksPerFile = 50
}
