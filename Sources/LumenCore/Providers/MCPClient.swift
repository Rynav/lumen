import Foundation

/// A user-configured MCP server launched over stdio. No secret env is passed; the
/// server inherits the same scrubbed environment as agent commands.
public struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var arguments: [String]
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, command: String, arguments: [String] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.command = command; self.arguments = arguments; self.enabled = enabled
    }
}

public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
}

public enum MCPError: LocalizedError, Equatable {
    case unavailable(String)
    case notConnected
    case protocolError(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let command): "MCP server program “\(command)” was not found on Lumen's trusted path."
        case .notConnected: "The MCP server is not connected."
        case .protocolError(let message): "MCP protocol error: \(message)"
        case .serverError(let message): message
        }
    }
}

/// Minimal MCP client: newline-delimited JSON-RPC 2.0 over a child process's stdio.
public actor MCPClient {
    public let config: MCPServerConfig
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]

    public init(config: MCPServerConfig) { self.config = config }

    public var isConnected: Bool { process?.isRunning == true }

    public func connect() async throws {
        if process != nil {
            if process?.isRunning == true { return }
            disconnect()
        }
        guard let executable = try? CommandPolicy.resolveExecutable(config.command) else {
            throw MCPError.unavailable(config.command)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = config.arguments
        process.environment = CommandPolicy.environment()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw MCPError.unavailable(config.command) }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer.removeAll()
        let handle = stdout.fileHandleForReading
        readTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines { await self?.handle(line: line) }
            } catch {}
            await self?.failPending(MCPError.notConnected)
        }
        _ = try await request("initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Lumen"), "version": .string("1.0")])
        ]))
        try notify("notifications/initialized", params: .object([:]))
    }

    public func disconnect() {
        readTask?.cancel(); readTask = nil
        process?.terminate()
        process = nil
        input = nil
        failPending(MCPError.notConnected)
    }

    public func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list", params: .object([:]))
        let tools = result["tools"]?.array ?? []
        return tools.compactMap { value in
            guard let name = value["name"]?.string, !name.isEmpty else { return nil }
            return MCPTool(name: name,
                           description: value["description"]?.string ?? "",
                           inputSchema: value["inputSchema"] ?? .object(["type": .string("object")]))
        }
    }

    /// Returns a single text result; non-text content is summarized by type.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let result = try await request("tools/call", params: .object([
            "name": .string(name), "arguments": arguments
        ]))
        if case .bool(true) = result["isError"] { throw MCPError.serverError("The MCP tool reported an error.") }
        let content = result["content"]?.array ?? []
        let text = content.compactMap { part -> String? in
            if part["type"]?.string == "text" { return part["text"]?.string }
            if let type = part["type"]?.string { return "[\(type) content]" }
            return nil
        }.joined(separator: "\n")
        return text.isEmpty ? "The MCP tool returned no text output." : text
    }

    private func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard process?.isRunning == true, input != nil else { throw MCPError.notConnected }
        let id = nextID; nextID += 1
        let message: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(message) }
            catch { pending[id] = nil; continuation.resume(throwing: MCPError.protocolError("write failed")) }
        }
    }

    private func notify(_ method: String, params: JSONValue) throws {
        try write(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    private func write(_ message: JSONValue) throws {
        guard let input else { throw MCPError.notConnected }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func handle(line: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return }
        guard let id = value["id"]?.number.map({ Int($0) }) else { return } // ignore notifications
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = value["error"] {
            continuation.resume(throwing: MCPError.serverError(error["message"]?.string ?? "MCP request failed."))
        } else {
            continuation.resume(returning: value["result"] ?? .null)
        }
    }

    private func failPending(_ error: MCPError) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
