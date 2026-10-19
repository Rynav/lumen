import Foundation

public struct ToolRegistry: Sendable {
    public let workspace: WorkspaceService
    public init(workspace: WorkspaceService) { self.workspace = workspace }

    public static let definitions: [ToolDefinition] = [
        definition("list_files", "List project files recursively. Hidden files and build/vendor folders are excluded. Returns at most 500 paths.",
                   properties: ["path": string("Folder relative to project root; defaults to .")]),
        definition("read_file", "Read a UTF-8 project file (up to 1 MB), with line numbers and bounded output.", properties: [
            "path": string("File path relative to project root"),
            "offset": .object(["type": .string("integer"), "minimum": .number(1)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(500)])
        ], required: ["path"]),
        definition("search_files", "Find literal, case-sensitive text in project files. Returns at most 100 matches with paths and line numbers.",
                   properties: ["query": string("Literal text to find"), "path": string("Folder to search; defaults to .")], required: ["query"]),
        definition("edit_file", "Propose one exact text replacement in a UTF-8 file. old_text must match exactly once. For a NEW file use empty old_text; its parent folder must already exist. Always waits for user approval of a visual diff before writing. Rejected edits must not be retried unless the user asks.",
                   properties: ["path": string("File relative to project root"), "old_text": string("Exact, unique existing text; empty only for a new file"),
                                "new_text": string("Replacement text, or the complete contents of a new file")], required: ["path", "old_text", "new_text"]),
        definition("run_command", "Propose a non-interactive command and wait for user approval. Use a program NAME and a literal argument array, not a shell expression. Example: executable=swift, arguments=[test]. Run a project shell script with executable=bash, arguments=[scripts/test.sh]. Shell inline code, blocked programs/options, and paths outside the project are rejected. Output is streamed, merged and bounded; background children are terminated when the command finishes. Never retry a rejected command without a new user request.", properties: [
            "executable": string("Program name from the trusted search path; no absolute paths or shell expressions"),
            "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "directory": string("Working directory relative to project root; defaults to ."),
            "timeout_seconds": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(600)])
        ], required: ["executable"])
    ]

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    /// The definitions a run advertises. `approval == nil` means no approval gate
    /// exists, so the tools that always require one are withheld. The prompt's
    /// tool guidance and the provider request both derive from this, so they can
    /// never disagree.
    public static func definitions(approvalIsEnabled: Bool) -> [ToolDefinition] {
        approvalIsEnabled ? definitions : definitions.filter { !approvalRequired.contains($0.name) }
    }

    /// Tools that can change the machine, and therefore always need a gate.
    public static let approvalRequired: Set<String> = ["edit_file", "run_command"]

    private static func definition(_ name: String, _ description: String, properties: [String: JSONValue], required: [String] = []) -> ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)
        ]))
    }

    public func execute(_ call: ToolCall, approval: ApprovalGate? = nil,
                        onProposal: @Sendable (FileEditProposal) -> Void = { _ in },
                        onApplied: @Sendable (AppliedChange) -> Void = { _ in },
                        onCommandProposal: @Sendable (CommandProposal) -> Void = { _ in },
                        onCommandUpdate: @escaping @Sendable (CommandUpdate) -> Void = { _ in }) async throws -> ToolResult {
        try Task.checkCancellation()
        do {
            guard let args = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)).object,
                  let definition = Self.definitions.first(where: { $0.name == call.name }),
                  let properties = definition.parameters["properties"]?.object,
                  args.keys.allSatisfy({ properties[$0] != nil }) else { throw WorkspaceError.invalidArguments }
            func string(_ key: String, default fallback: String? = nil) throws -> String {
                if let value = args[key] {
                    guard let text = value.string else { throw WorkspaceError.invalidArguments }
                    return text
                }
                guard let fallback else { throw WorkspaceError.invalidArguments }
                return fallback
            }
            func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
                guard let value = args[key] else { return fallback }
                guard let number = value.number, number.isFinite, number.rounded() == number,
                      number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
                    throw WorkspaceError.invalidArguments
                }
                guard let integer = Int(exactly: number) else { throw WorkspaceError.invalidArguments }
                return integer
            }
            let content: String
            switch call.name {
            case "list_files": content = try await workspace.listFiles(path: string("path", default: "."))
            case "read_file": content = try await workspace.readFile(path: string("path"),
                offset: integer("offset", default: 1, range: 1...Int.max),
                limit: integer("limit", default: 200, range: 1...500))
            case "search_files": content = try await workspace.search(query: string("query"), path: string("path", default: "."))
            case "run_command":
                guard let approval else { throw ProviderError.unsupported("Commands require an explicit user approval gate.") }
                let arguments: [String]
                if let value = args["arguments"] {
                    guard let array = value.array, array.allSatisfy({ $0.string != nil }) else { throw WorkspaceError.invalidArguments }
                    arguments = array.compactMap(\.string)
                } else { arguments = [] }
                let proposal = try await workspace.prepareCommand(executable: string("executable"), arguments: arguments,
                    directory: string("directory", default: "."), timeoutSeconds: integer("timeout_seconds", default: 120, range: 1...600))
                do {
                    let approved = await approval.request(id: proposal.id) { onCommandProposal(proposal) }
                    try Task.checkCancellation()
                    guard approved else {
                        await workspace.discardCommand(proposal.id)
                        return ToolResult(callID: call.id, content: "The user rejected this command. Nothing was run. Do not retry without a new user request.", isError: true)
                    }
                    let result = try await workspace.runCommand(proposal.id, onUpdate: onCommandUpdate)
                    try Task.checkCancellation()
                    let status = result.timedOut ? "Timed out" : result.cancelled ? "Cancelled" : "Exit code \(result.exitCode)"
                    return ToolResult(callID: call.id, content: "\(status). Output bytes: \(result.totalBytes).\n\(result.output)", isError: !result.succeeded)
                } catch {
                    await workspace.discardCommand(proposal.id)
                    throw error
                }
            case "edit_file":
                guard let approval else { throw ProviderError.unsupported("Editing requires an explicit user approval gate.") }
                let proposal = try await workspace.prepareEdit(path: string("path"), oldText: string("old_text"), newText: string("new_text"))
                do {
                    let approved = await approval.request(proposal, notify: onProposal)
                    try Task.checkCancellation()
                    guard approved else {
                        await workspace.discardEdit(proposal.id)
                        return ToolResult(callID: call.id, content: "The user rejected this edit. No file was changed. Do not retry it without a new user request.", isError: true)
                    }
                    let change = try await workspace.applyEdit(proposal.id)
                    onApplied(change)
                    content = "Applied user-approved edit to \(proposal.path). Recovery snapshot: \(change.backupPath)."
                } catch {
                    await workspace.discardEdit(proposal.id)
                    throw error
                }
            default: throw WorkspaceError.invalidArguments
            }
            return ToolResult(callID: call.id, content: content)
        } catch is CancellationError { throw CancellationError() }
        catch { return ToolResult(callID: call.id, content: error.localizedDescription, isError: true) }
    }
}
