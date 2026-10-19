import Foundation
import Testing
@testable import LumenCore

@Suite struct PatchTests {
    private func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func text(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func patchError(_ patch: String, workspace: WorkspaceService) async -> String? {
        do {
            _ = try await workspace.preparePatch(PatchParser.parse(patch))
            return nil
        } catch { return error.localizedDescription }
    }

    @Test func patchAppliesUpdatesAddsAndDeletesInOneReview() async throws {
        let root = try fixture([
            "src/a.txt": "head\nold\ntail\n",
            "src/b.txt": "one\ntwo\n",
            "src/old.txt": "remove me\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: root.appendingPathComponent("src/old.txt").path)
        let workspace = try WorkspaceService(root: root)
        let patch = """
        *** Begin Patch
        *** Update File: src/a.txt
        @@
         head
        -old
        +new
         tail
        *** Update File: src/b.txt
        @@
        -one
        +ONE
        *** Add File: src/new.txt
        +created
        *** Delete File: src/old.txt
        *** End Patch
        """
        let proposals = try await workspace.preparePatch(PatchParser.parse(patch))
        #expect(proposals.map(\.path) == ["src/a.txt", "src/b.txt", "src/new.txt", "src/old.txt"])
        #expect(try text(root, "src/a.txt") == "head\nold\ntail\n")
        #expect(try text(root, "src/b.txt") == "one\ntwo\n")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("src/old.txt").path))

        for proposal in proposals { _ = try await workspace.applyEdit(proposal.id) }
        #expect(try text(root, "src/a.txt") == "head\nnew\ntail\n")
        #expect(try text(root, "src/b.txt") == "ONE\ntwo\n")
        #expect(try text(root, "src/new.txt") == "created\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("src/old.txt").path))

        for proposal in proposals.reversed() { try await workspace.undoEdit(proposal.id) }
        #expect(try text(root, "src/a.txt") == "head\nold\ntail\n")
        #expect(try text(root, "src/b.txt") == "one\ntwo\n")
        #expect(try text(root, "src/old.txt") == "remove me\n")
        #expect(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("src/old.txt").path)[.posixPermissions] as? Int == 0o755)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("src/new.txt").path))
    }

    @Test func patchContextDisambiguatesRepeatedCode() async throws {
        let source = "func first() {\n    print(\"x\")\n}\nfunc second() {\n    print(\"x\")\n}\n"
        let root = try fixture(["src/code.swift": source])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let patch = """
        *** Begin Patch
        *** Update File: src/code.swift
        @@
         func second() {
        -    print("x")
        +    print("y")
         }
        *** End Patch
        """
        let proposals = try await workspace.preparePatch(PatchParser.parse(patch))
        _ = try await workspace.applyEdit(try #require(proposals.first).id)
        #expect(try text(root, "src/code.swift") == "func first() {\n    print(\"x\")\n}\nfunc second() {\n    print(\"y\")\n}\n")
    }

    @Test func patchFillsEmptyFilesAndRejectsCRLFLineEndings() async throws {
        let root = try fixture(["src/empty.txt": "", "src/crlf.txt": "a\r\nb\r\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let empty = """
        *** Begin Patch
        *** Update File: src/empty.txt
        @@
        +hello
        *** End Patch
        """
        let proposals = try await workspace.preparePatch(PatchParser.parse(empty))
        _ = try await workspace.applyEdit(try #require(proposals.first).id)
        #expect(try text(root, "src/empty.txt") == "hello\n")
        #expect(try Data(contentsOf: root.appendingPathComponent("src/crlf.txt")) == Data("a\r\nb\r\n".utf8))
        let crlfPatch = FilePatch.update(path: "src/crlf.txt", hunks: [PatchHunk(oldLines: ["a"], newLines: ["A"])])
        #expect(throws: WorkspaceError.self) { try crlfPatch.applying(to: "a\r\nb\r\n") }

        let crlf = """
        *** Begin Patch
        *** Update File: src/crlf.txt
        @@
        -a
        +A
        *** End Patch
        """
        let message = await patchError(crlf, workspace: workspace)
        #expect(message?.contains("CRLF") == true, "\(message ?? "nil")")
        #expect(try text(root, "src/crlf.txt") == "a\r\nb\r\n")
    }

    @Test func patchRejectsAmbiguousMissingAndUnsafeEditsWithoutWriting() async throws {
        let root = try fixture(["src/a.txt": "same\nsame\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)

        let ambiguous = """
        *** Begin Patch
        *** Update File: src/a.txt
        @@
        -same
        +changed
        *** End Patch
        """
        let ambiguousMessage = await patchError(ambiguous, workspace: workspace)
        #expect(ambiguousMessage?.contains("matches more than once") == true)

        let missing = """
        *** Begin Patch
        *** Update File: src/a.txt
        @@
        -absent
        +changed
        *** End Patch
        """
        let missingMessage = await patchError(missing, workspace: workspace)
        #expect(missingMessage?.contains("does not match") == true)

        let existing = """
        *** Begin Patch
        *** Add File: src/a.txt
        +new
        *** End Patch
        """
        let existingMessage = await patchError(existing, workspace: workspace)
        #expect(existingMessage?.contains("already exists") == true)

        let absent = """
        *** Begin Patch
        *** Delete File: src/absent.txt
        *** End Patch
        """
        let absentMessage = await patchError(absent, workspace: workspace)
        #expect(absentMessage?.contains("does not exist") == true)

        let escape = """
        *** Begin Patch
        *** Update File: ../escape.txt
        @@
        -a
        +b
        *** End Patch
        """
        let escapeMessage = await patchError(escape, workspace: workspace)
        #expect(escapeMessage?.contains("inside the project") == true)

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let protected = """
        *** Begin Patch
        *** Add File: .GIT/config
        +x
        *** End Patch
        """
        let protectedMessage = await patchError(protected, workspace: workspace)
        #expect(protectedMessage?.contains("Git internals") == true)
        #expect(try text(root, "src/a.txt") == "same\nsame\n")
    }

    @Test func patchFormatRequiresBeginEndFilesAndChanges() {
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Update File: a\n@@\n-x\n+y\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Update File: a\n@@\n-x\n+y\n")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Unknown: a\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Add File: a\nnot prefixed\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Update File: a\n@@\n context\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Update File: a\n@@\n-x\n+y\n*** Update File: a\n@@\n-y\n+z\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Add File: a\n+x\n\n*** End Patch")
        }
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n*** Update File: a\n@@\n-x\n+y\n\n*** End Patch")
        }
        let tooManyFiles = (0..<33).map { "*** Add File: file\($0).txt\n+x" }.joined(separator: "\n")
        #expect(throws: WorkspaceError.self) {
            try PatchParser.parse("*** Begin Patch\n\(tooManyFiles)\n*** End Patch")
        }
    }

    @Test func applyPatchToolUsesOneApprovalAndAppliesSelectedFiles() async throws {
        let root = try fixture(["a.txt": "a\n", "b.txt": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let patch = """
        *** Begin Patch
        *** Update File: a.txt
        @@
        -a
        +A
        *** Update File: b.txt
        @@
        -b
        +B
        *** End Patch
        """
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["patch": .string(patch)])), as: UTF8.self)
        let gate = ApprovalGate()
        let (events, continuation) = AsyncStream<EditBatchProposal>.makeStream()
        let task = Task {
            try await ToolRegistry(workspace: workspace).execute(
                ToolCall(id: "patch", name: "apply_patch", arguments: arguments),
                approval: gate, onBatchProposal: { continuation.yield($0) })
        }
        var iterator = events.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        continuation.finish()
        #expect(batch.edits.count == 2)
        #expect(try text(root, "a.txt") == "a\n")
        #expect(try text(root, "b.txt") == "b\n")

        await gate.decideBatch(id: batch.id, approved: [batch.edits[0].id])
        let result = try await task.value
        #expect(try text(root, "a.txt") == "A\n")
        #expect(try text(root, "b.txt") == "b\n")
        #expect(!result.isError)
        #expect(result.content.contains("a.txt: applied"))
        #expect(result.content.contains("b.txt: not approved"))
    }

    @Test func applyPatchToolRejectsEverythingWithoutWriting() async throws {
        let root = try fixture(["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let patch = """
        *** Begin Patch
        *** Update File: a.txt
        @@
        -a
        +A
        *** End Patch
        """
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["patch": .string(patch)])), as: UTF8.self)
        let gate = ApprovalGate()
        let (events, continuation) = AsyncStream<EditBatchProposal>.makeStream()
        let task = Task {
            try await ToolRegistry(workspace: workspace).execute(
                ToolCall(id: "patch", name: "apply_patch", arguments: arguments),
                approval: gate, onBatchProposal: { continuation.yield($0) })
        }
        var iterator = events.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        continuation.finish()
        await gate.decideBatch(id: batch.id, approved: [])
        let result = try await task.value
        #expect(try text(root, "a.txt") == "a\n")
        #expect(result.isError)
        #expect(result.content.hasPrefix("The user rejected this patch"))
        await #expect(throws: WorkspaceError.unknownProposal) { try await workspace.applyEdit(batch.edits[0].id) }
    }

    @Test func applyPatchKeepsAppliedFilesWhenAnotherChanged() async throws {
        let root = try fixture(["a.txt": "a\n", "b.txt": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let patch = """
        *** Begin Patch
        *** Update File: a.txt
        @@
        -a
        +A
        *** Update File: b.txt
        @@
        -b
        +B
        *** End Patch
        """
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["patch": .string(patch)])), as: UTF8.self)
        let gate = ApprovalGate()
        let (events, continuation) = AsyncStream<EditBatchProposal>.makeStream()
        let task = Task {
            try await ToolRegistry(workspace: workspace).execute(
                ToolCall(id: "patch", name: "apply_patch", arguments: arguments),
                approval: gate, onBatchProposal: { continuation.yield($0) })
        }
        var iterator = events.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        continuation.finish()
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("b.txt"))

        await gate.decideBatch(id: batch.id, approved: Set(batch.edits.map(\.id)))
        let result = try await task.value
        #expect(try text(root, "a.txt") == "A\n")
        #expect(try text(root, "b.txt") == "changed\n")
        #expect(result.isError)
        #expect(result.content.contains("a.txt: applied"))
        #expect(result.content.contains("b.txt: failed"))
    }

    @Test func agentEmitsOneBatchApprovalAndContinues() async throws {
        let root = try fixture(["a.txt": "a\n", "b.txt": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let patch = """
        *** Begin Patch
        *** Update File: a.txt
        @@
        -a
        +A
        *** Update File: b.txt
        @@
        -b
        +B
        *** End Patch
        """
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["patch": .string(patch)])), as: UTF8.self)
        let call = ToolCall(id: "patch", name: "apply_patch", arguments: arguments)
        let provider = MockProvider([[.toolCall(call), .finished], [.text("Applied."), .finished]])
        let gate = ApprovalGate()
        var reviewed = false
        for try await event in AgentSession().run(messages: [], model: "mock", provider: provider,
            workspace: try WorkspaceService(root: root), maxIterations: 3, approval: gate) {
            if case .editBatch(let batch) = event {
                reviewed = true
                #expect(batch.edits.count == 2)
                #expect(try text(root, "a.txt") == "a\n")
                #expect(batch.edits.allSatisfy { $0.path == "a.txt" || $0.path == "b.txt" })
                await gate.decideBatch(id: batch.id, approved: Set(batch.edits.map(\.id)))
            }
        }
        #expect(reviewed)
        #expect(try text(root, "a.txt") == "A\n")
        #expect(try text(root, "b.txt") == "B\n")
        #expect(provider.history.count == 2)
    }
}
