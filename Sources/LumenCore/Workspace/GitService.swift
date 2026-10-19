import Foundation

/// One row from `git status --porcelain`. `index`/`worktree` are the raw XY letters.
public struct GitFileStatus: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let index: String
    public let worktree: String
    public var isUntracked: Bool { index == "?" }
    public var label: String {
        if isUntracked { return "New" }
        if index == "A" || worktree == "A" { return "Added" }
        if index == "D" || worktree == "D" { return "Deleted" }
        if index == "R" { return "Renamed" }
        if index == "M" || worktree == "M" { return "Modified" }
        return "Changed"
    }
}

public enum GitError: LocalizedError, Equatable {
    case unavailable
    case notARepository
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Git is not installed or not on Lumen's trusted path."
        case .notARepository: "This folder is not a Git repository."
        case .failed(let message): message.isEmpty ? "The Git command failed." : message
        }
    }
}

/// Read-only review plus staging/commit for the open project. Destructive operations
/// (`reset --hard`, `checkout .`, `clean`) are intentionally not offered; per-change Undo
/// already restores the agent's edits from recovery snapshots.
public struct GitService: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func isRepository() async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "true"
    }

    public func status() async throws -> [GitFileStatus] {
        let output = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        return Self.parseStatus(output)
    }

    /// Tracked changes versus HEAD (untracked files appear only in `status`).
    public func diff() async throws -> String {
        try await run(["diff", "HEAD", "--no-color", "--no-ext-diff"])
    }

    public func commit(message: String) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.failed("Enter a commit message.") }
        _ = try await run(["add", "-A"])
        _ = try await run(["commit", "-m", trimmed])
    }

    static func parseStatus(_ output: String) -> [GitFileStatus] {
        var entries: [GitFileStatus] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.count >= 3 else { continue }
            let chars = Array(token)
            let status = String(chars[0...1])
            let path = String(token.dropFirst(3))
            // A rename/copy record carries the original path as the next NUL token.
            if status.first == "R" || status.first == "C" { index += 1 }
            guard !path.isEmpty else { continue }
            entries.append(GitFileStatus(path: path, index: String(chars[0]), worktree: String(chars[1])))
        }
        return entries
    }

    private func run(_ arguments: [String]) async throws -> String {
        let root = self.root
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSync(root: root, arguments: arguments)
        }.value
    }

    private static func runSync(root: URL, arguments: [String]) throws -> String {
        guard let executable = try? CommandPolicy.resolveExecutable("git") else { throw GitError.unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", root.path] + arguments
        process.environment = CommandPolicy.environment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw GitError.failed("Git could not be launched.") }

        // Bounded wait; these commands are quick and read-only except add/commit.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            throw GitError.failed("Git timed out.")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(String(message.prefix(500)))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
