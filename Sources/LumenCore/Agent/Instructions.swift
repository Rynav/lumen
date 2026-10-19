import Foundation

/// One rendered instruction source, keyed like OpenCode's `Instructions.Key`.
public struct InstructionSource: Equatable, Sendable {
    public let key: String
    public let text: String
    public init(key: String, text: String) { self.key = key; self.text = text }
}

/// The instruction baseline: the second system part, ordered most to least shared
/// so the stable prefix stays reusable. Ported from
/// `opencode/packages/core/src/session/context.ts:150`,
/// `instructions/builtins.ts`, and `instruction-discovery.ts` (MIT).
///
/// Deviations from OpenCode, all documented in `SYSTEM_PROMPT_AND_TOOLS.md`:
/// there is no ancestor walk above the workspace root, no per-source change
/// tracking, and the global instruction file is read as app-owned state.
public enum Instructions {
    /// Sessions live in the home directory alongside `config.json`.
    public static var defaultGlobalDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumen", isDirectory: true)
    }

    public static func render(_ sources: [InstructionSource]) -> String {
        sources.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Reads the instruction files and composes the baseline for one request.
    public static func load(workspace: WorkspaceService?, globalDirectory: URL = Instructions.defaultGlobalDirectory,
                            date: Date = Date()) async -> [InstructionSource] {
        let global = (try? WorkspaceService.loadAppFile(named: fileName, in: globalDirectory))
            .flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
        var project: String?
        var hasGitRepository: Bool?
        if let workspace {
            project = try? await workspace.readOptionalText(path: fileName)
            hasGitRepository = await workspace.hasGitDirectory()
        }
        return baseline(global: global, project: project, workspaceRoot: workspace?.root,
                        hasGitRepository: hasGitRepository, date: date, globalDirectory: globalDirectory)
    }

    /// Pure composition, so ordering and rendering are testable without a workspace.
    public static func baseline(global: String?, project: String?, workspaceRoot: URL?,
                                hasGitRepository: Bool?, date: Date,
                                globalDirectory: URL = Instructions.defaultGlobalDirectory,
                                platform: String? = nil) -> [InstructionSource] {
        let platform = platform ?? Instructions.platform
        var sources: [InstructionSource] = []
        // One source for all discovered files, keyed and ordered as OpenCode's
        // discovery source is: the global file, then the project file.
        var files: [(URL, String)] = []
        if let content = global?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            files.append((globalDirectory.appendingPathComponent(fileName), content))
        }
        if let root = workspaceRoot,
           let content = project?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            files.append((root.appendingPathComponent(fileName), content))
        }
        if !files.isEmpty {
            sources.append(InstructionSource(key: "core/instructions",
                                             text: files.map { "Instructions from: \($0.0.path)\n\($0.1)" }.joined(separator: "\n\n")))
        }
        sources.append(InstructionSource(key: "core/date", text: "Today's date: \(dateString(date))"))
        guard let root = workspaceRoot else {
            sources.append(InstructionSource(key: "core/no-project",
                                             text: "No project folder is open. File and command tools are unavailable; answer from the conversation alone."))
            return sources
        }
        sources.append(InstructionSource(key: "core/environment",
                                         text: environment(root: root, hasGitRepository: hasGitRepository, platform: platform)))
        return sources
    }

    /// OpenCode renders `core/date` with `toDateString()`. Lumen sends a
    /// timezone-independent `Month D, YYYY` day so the rendered prompt is stable
    /// within a day and identical on every machine.
    static func dateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "UTC") else { return "\(date)" }
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "\(date)" }
        let months = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        return "\(months[month - 1]) \(day), \(year)"
    }

    static var platform: String {
        #if os(macOS)
        "darwin (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))"
        #elseif os(Linux)
        "linux"
        #else
        "unknown"
        #endif
    }

    static let fileName = "AGENTS.md"

    private static func environment(root: URL, hasGitRepository: Bool?, platform: String) -> String {
        [
            "Here is some useful information about the environment you are running in:",
            "<env>",
            "  Working directory: \(root.path)",
            "  Workspace root folder: \(root.path)",
            "  Is directory a git repo: \(hasGitRepository == true ? "yes" : "no")",
            "  Platform: \(platform)",
            "</env>",
        ].joined(separator: "\n")
    }
}
