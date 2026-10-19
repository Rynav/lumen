import Darwin
import Foundation
import Testing
@testable import LumenCore

@Suite struct WorkspaceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("first\nneedle 🌍\nlast".utf8).write(to: root.appendingPathComponent("src/example.swift"))
        try Data([0, 255]).write(to: root.appendingPathComponent("binary"))
        try Data("hidden needle".utf8).write(to: root.appendingPathComponent(".secret"))
        return root
    }

    @Test func readListAndSearch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        #expect(try await workspace.listFiles() == "binary\nsrc/example.swift")
        #expect(try await workspace.listFiles(path: "src") == "src/example.swift")
        #expect(try await workspace.readFile(path: "src/example.swift", offset: 2, limit: 1) == "2: needle 🌍\n[Lines 2-2 of 3]")
        #expect(try await workspace.readFile(path: root.appendingPathComponent("src/example.swift").path).contains("first"))
        #expect(try await workspace.search(query: "needle").contains("src/example.swift:2: needle 🌍"))
        #expect(try await workspace.search(query: "NEEDLE").hasPrefix("No matches."))
        #expect(try await workspace.search(query: "hidden").hasPrefix("No matches."))
        await #expect(throws: WorkspaceError.notText) { try await workspace.readFile(path: "binary") }
    }

    @Test func escapesAndSpecialFilesAreRejected() async throws {
        let root = try fixture()
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside secret".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let workspace = try WorkspaceService(root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escapeFolder"), withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("src/example.swift"))
        for path in ["../\(outside.lastPathComponent)", outside.path, "escape", "src/../binary", "bad\u{0}path"] {
            await #expect(throws: WorkspaceError.outsideWorkspace) { try await workspace.readFile(path: path) }
        }
        await #expect(throws: WorkspaceError.outsideWorkspace) { try await workspace.listFiles(path: outside.deletingLastPathComponent().path) }
        await #expect(throws: WorkspaceError.outsideWorkspace) { try await workspace.search(query: "secret", path: "escapeFolder") }
        #expect(try await workspace.readFile(path: "alias").contains("first"))
        #expect(try await workspace.listFiles() == "binary\nsrc/example.swift")
        await #expect(throws: WorkspaceError.unreadable) { try await workspace.readFile(path: "src") }
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        await #expect(throws: WorkspaceError.unreadable) { try await workspace.readFile(path: "pipe") }
        try Data(repeating: 65, count: 1_048_577).write(to: root.appendingPathComponent("large"))
        await #expect(throws: WorkspaceError.tooLarge) { try await workspace.readFile(path: "large") }
        await #expect(throws: WorkspaceError.invalidArguments) { try await workspace.readFile(path: "binary", offset: 0) }
    }

    @Test func outputAndToolArgumentsAreBounded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "x", count: 40_000).utf8).write(to: root.appendingPathComponent("line"))
        let workspace = try WorkspaceService(root: root)
        let output = try await workspace.readFile(path: "line")
        #expect(output.count < 24_100)
        #expect(output.contains("Output truncated"))
        let registry = ToolRegistry(workspace: workspace)
        #expect(try await registry.execute(ToolCall(id: "unknown", name: "run_command", arguments: #"{"command":"pwd"}"#)).isError)
        for arguments in [#"{"path":"line","limit":501}"#, #"{"path":"line","offset":1.5}"#, #"{"path":"line","offset":9223372036854775808}"#, #"{"path":"line","extra":true}"#, #"{"path":42}"#, "not json"] {
            #expect(try await registry.execute(ToolCall(id: "bad", name: "read_file", arguments: arguments)).isError)
        }
        let result = try await registry.execute(ToolCall(id: "ok", name: "search_files", arguments: #"{"query":"needle"}"#))
        #expect(!result.isError)
        #expect(result.content.contains("example.swift:2"))
    }
}
