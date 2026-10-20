import Foundation
import Testing
@testable import LumenCore

@Suite struct EditingTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("first\nold value\nlast\n".utf8).write(to: root.appendingPathComponent("src/file.txt"))
        return root
    }

    @Test func proposalDoesNotWriteAndApprovedEditKeepsRecoveryAndMode() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src/file.txt")
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: oldDate], ofItemAtPath: file.path)
        let workspace = try WorkspaceService(root: root)
        let proposal = try await workspace.prepareEdit(path: "src/file.txt", oldText: "old value", newText: "new and much longer value")
        #expect(try String(contentsOf: file, encoding: .utf8) == proposal.before)
        let change = try await workspace.applyEdit(proposal.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == proposal.after)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o755)
        let changedDate = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        #expect(changedDate > oldDate)
        let backup = try JSONDecoder().decode(FileEditProposal.self, from: Data(contentsOf: root.appendingPathComponent(change.backupPath)))
        #expect(backup == proposal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".lumen/backups").path).contains { $0.hasSuffix(".original") })
        try await workspace.undoEdit(proposal.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == proposal.before)
        await #expect(throws: WorkspaceError.unknownProposal) { try await workspace.applyEdit(proposal.id) }
    }

    @Test func createsAndUndoesNewFilesWithoutReplacingExistingFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let created = try await workspace.prepareEdit(path: "src/new.swift", oldText: "", newText: "let answer = 42\n")
        #expect(created.before == nil)
        _ = try await workspace.applyEdit(created.id)
        #expect(try await workspace.readFile(path: "src/new.swift").contains("42"))
        try await workspace.undoEdit(created.id)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("src/new.swift").path))
        let stale = try await workspace.prepareEdit(path: "src/new.swift", oldText: "", newText: "agent")
        try Data("user created this".utf8).write(to: root.appendingPathComponent("src/new.swift"))
        await #expect(throws: WorkspaceError.conflict) { try await workspace.applyEdit(stale.id) }
        #expect(try String(contentsOf: root.appendingPathComponent("src/new.swift"), encoding: .utf8) == "user created this")
        await #expect(throws: WorkspaceError.ambiguousEdit) { try await workspace.prepareEdit(path: "src/file.txt", oldText: "", newText: "overwrite") }
    }

    @Test func undoWorksAfterRelaunchFromTheSavedProposal() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src/file.txt")
        let workspace = try WorkspaceService(root: root)
        let proposal = try await workspace.prepareEdit(path: "src/file.txt", oldText: "old value", newText: "new value")
        let change = try await workspace.applyEdit(proposal.id)
        let backup = try JSONDecoder().decode(FileEditProposal.self,
            from: Data(contentsOf: root.appendingPathComponent(change.backupPath)))
        let restored = AppliedChange(proposal: backup, backupPath: change.backupPath)

        // The new workspace has no in-memory ledger, but still refuses to overwrite newer work.
        let reopened = try WorkspaceService(root: root)
        try Data("edited elsewhere".utf8).write(to: file)
        await #expect(throws: WorkspaceError.conflict) { try await reopened.undoEdit(restored) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited elsewhere")
        try Data((proposal.after ?? "").utf8).write(to: file)
        try await reopened.undoEdit(restored)
        #expect(try String(contentsOf: file, encoding: .utf8) == proposal.before)
    }

    @Test func staleFileFolderAndUndoAreRejected() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceService(root: root)
        let file = root.appendingPathComponent("src/file.txt")
        let edit = try await workspace.prepareEdit(path: "src/file.txt", oldText: "old value", newText: "new value")
        try Data("manual change".utf8).write(to: file)
        await #expect(throws: WorkspaceError.conflict) { try await workspace.applyEdit(edit.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "manual change")
        let next = try await workspace.prepareEdit(path: "src/file.txt", oldText: "manual change", newText: "approved")
        _ = try await workspace.applyEdit(next.id)
        try Data("another manual change".utf8).write(to: file)
        await #expect(throws: WorkspaceError.conflict) { try await workspace.undoEdit(next.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "another manual change")
        let parent = try await workspace.prepareEdit(path: "src/file.txt", oldText: "another", newText: "different")
        try FileManager.default.moveItem(at: root.appendingPathComponent("src"), to: root.appendingPathComponent("src-old"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("another manual change".utf8).write(to: file)
        await #expect(throws: WorkspaceError.conflict) { try await workspace.applyEdit(parent.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "another manual change")
    }

    @Test func editsRejectAmbiguityEscapesAndUnsafeRecoveryPaths() async throws {
        let root = try fixture()
        let outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let workspace = try WorkspaceService(root: root)
        try Data("aaa".utf8).write(to: root.appendingPathComponent("overlap"))
        await #expect(throws: WorkspaceError.ambiguousEdit) { try await workspace.prepareEdit(path: "overlap", oldText: "aa", newText: "x") }
        await #expect(throws: WorkspaceError.ambiguousEdit) { try await workspace.prepareEdit(path: "src/file.txt", oldText: "missing", newText: "x") }
        for path in ["../escape", outside.appendingPathComponent("src/file.txt").path] {
            await #expect(throws: WorkspaceError.outsideWorkspace) { try await workspace.prepareEdit(path: path, oldText: "old", newText: "new") }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        await #expect(throws: WorkspaceError.protectedPath) { try await workspace.prepareEdit(path: ".git/config", oldText: "", newText: "x") }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside.appendingPathComponent("src/file.txt"))
        await #expect(throws: WorkspaceError.outsideWorkspace) { try await workspace.prepareEdit(path: "escape", oldText: "old", newText: "new") }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".lumen"), withDestinationURL: outside)
        let proposal = try await workspace.prepareEdit(path: "src/file.txt", oldText: "old", newText: "new")
        await #expect(throws: WorkspaceError.writeFailed) { try await workspace.applyEdit(proposal.id) }
        #expect(try String(contentsOf: root.appendingPathComponent("src/file.txt"), encoding: .utf8).contains("old"))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("backups").path))
    }

    @Test func equivalentUnicodeIsStillAStaleByteChange() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src/file.txt")
        try Data("caf\u{e9}".utf8).write(to: file)
        let workspace = try WorkspaceService(root: root)
        let proposal = try await workspace.prepareEdit(path: "src/file.txt", oldText: "caf\u{e9}", newText: "coffee")
        let replacement = Data("cafe\u{301}".utf8)
        try replacement.write(to: file)
        await #expect(throws: WorkspaceError.conflict) { try await workspace.applyEdit(proposal.id) }
        #expect(try Data(contentsOf: file) == replacement)
    }

    @Test func directoryTreeIsSortedLazyAndIncludesDotfiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignore".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let workspace = try WorkspaceService(root: root)
        let listing = try await workspace.directoryEntries()
        #expect(listing.entries.map(\.name) == ["src", ".gitignore"])
        #expect(listing.entries.first?.isDirectory == true)
        #expect(try await workspace.directoryEntries(path: "src").entries.map(\.path) == ["src/file.txt"])
        #expect(!listing.truncated)
    }

    @Test func diffReconstructsBothSidesIncludingDuplicateLinesAndEOF() {
        for (old, new) in [("a\nb\n", "a\nc\n"), ("a\nb\na", "b\na\nb"), ("", "new\n"), ("old", ""), ("a\n", "a"), ("same", "same")] {
            let rows = DiffLine.compare(old, new)
            #expect(rows.filter { $0.kind != .added }.map(\.text).joined(separator: "\n") == old)
            #expect(rows.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n") == new)
        }
    }
}
