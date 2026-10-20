import Darwin
import Foundation

public enum WorkspaceError: LocalizedError, Equatable {
    case invalidRoot, outsideWorkspace, unreadable, notText, tooLarge, invalidArguments
    case conflict, ambiguousEdit, protectedPath, unknownProposal, writeFailed
    case patch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "Choose an existing project folder."
        case .outsideWorkspace: "The path must stay inside the project folder."
        case .unreadable: "The file or folder could not be read."
        case .notText: "Only UTF-8 text files can be read."
        case .tooLarge: "This file exceeds the 1 MB read limit."
        case .invalidArguments: "Invalid tool arguments."
        case .conflict: "The file or its folder changed. The edit was stopped to protect newer work. Read it again before retrying; recovery files may have been kept."
        case .ambiguousEdit: "old_text must match exactly once. Use a larger, unique context; empty old_text is only for creating a new file."
        case .protectedPath: "Git internals and Lumen recovery files cannot be edited by the agent."
        case .unknownProposal: "This action is no longer pending."
        case .writeFailed: "The file could not be safely written. A recovery snapshot was kept if one was created."
        case .patch(let message): message
        }
    }
}

/// All project file access is confined here, including proposals, commits and recovery snapshots.
public actor WorkspaceService {
    public nonisolated let root: URL
    private let rootDescriptor: Int32
    private struct PendingEdit {
        let proposal: FileEditProposal
        let parentDevice: dev_t
        let parentInode: ino_t
    }
    private var pending: [UUID: PendingEdit] = [:]
    // In-memory ledger reconciles turns cancelled mid-apply; saved chats persist the undoable changes themselves.
    private var applied: [UUID: AppliedChange] = [:]
    private var appliedOrder: [UUID] = []
    private var appliedParents: [UUID: (device: dev_t, inode: ino_t)] = [:]
    private struct PreparedCommand {
        let proposal: CommandProposal
        let device: dev_t
        let inode: ino_t
    }
    private struct RunningCommand {
        let proposal: CommandProposal
        let control: CommandControl
        let task: Task<CommandResult, any Error>
    }
    private var preparedCommands: [UUID: PreparedCommand] = [:]
    private var runningCommands: [UUID: RunningCommand] = [:]
    private var commandHistory: [UUID: CommandUpdate] = [:]
    private var commandOrder: [UUID] = []

    public init(root: URL) throws {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.isFileURL,
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceError.invalidRoot
        }
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.invalidRoot }
        self.root = resolved
        rootDescriptor = descriptor
    }

    deinit { Darwin.close(rootDescriptor) }

    public func prepareCommand(executable: String, arguments: [String] = [], directory: String = ".", timeoutSeconds: Int = 120) throws -> CommandProposal {
        try Task.checkCancellation()
        try CommandPolicy.validate(executable: executable, arguments: arguments, timeout: timeoutSeconds)
        let program = try CommandPolicy.resolveExecutable(executable)
        let actualName = URL(fileURLWithPath: program).lastPathComponent
        try CommandPolicy.validate(executable: actualName, arguments: arguments, timeout: timeoutSeconds)
        let arguments = CommandPolicy.normalizedArguments(actualName, arguments)
        let folder = try resolve(directory)
        let descriptor = try openFile(folder.path)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw WorkspaceError.unreadable }
        for argument in arguments {
            let value = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? argument
            guard !value.hasPrefix("~") else { throw WorkspaceError.outsideWorkspace }
            if value.hasPrefix("/") || (value.contains("/") && !value.contains("://")) || value.split(separator: "/").contains("..") {
                _ = try resolve(value.hasPrefix("/") ? value : folder.appendingPathComponent(value).path)
            }
        }
        if CommandPolicy.isShell(executable) || CommandPolicy.isShell(URL(fileURLWithPath: program).lastPathComponent) {
            let index = CommandPolicy.shellScriptIndex(actualName, arguments: arguments)
            guard arguments.indices.contains(index) else { throw CommandError.blocked }
            let script = arguments[index]
            let file = try openFile(script.hasPrefix("/") ? script : folder.appendingPathComponent(script).path)
            defer { Darwin.close(file) }
            var scriptInfo = stat()
            guard fstat(file, &scriptInfo) == 0, (scriptInfo.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.unreadable }
        }
        let relativeFolder = relative(folder)
        let proposal = CommandProposal(id: UUID(), executable: executable, arguments: arguments,
            directory: relativeFolder.isEmpty ? "." : relativeFolder, timeoutSeconds: timeoutSeconds, executablePath: program)
        preparedCommands[proposal.id] = PreparedCommand(proposal: proposal, device: info.st_dev, inode: info.st_ino)
        return proposal
    }

    public func discardCommand(_ id: UUID) { preparedCommands[id] = nil }

    public func runCommand(_ id: UUID, onUpdate: @escaping @Sendable (CommandUpdate) -> Void = { _ in }) async throws -> CommandResult {
        try Task.checkCancellation()
        guard let prepared = preparedCommands.removeValue(forKey: id) else { throw WorkspaceError.unknownProposal }
        let proposal = prepared.proposal
        // Re-enforce policy even when a caller already approved the proposal.
        try CommandPolicy.validate(executable: proposal.executable, arguments: proposal.arguments, timeout: proposal.timeoutSeconds)
        guard try CommandPolicy.resolveExecutable(proposal.executable) == proposal.executablePath else { throw CommandError.executableUnavailable }
        let directory = try openFile(proposal.directory)
        defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_dev == prepared.device, info.st_ino == prepared.inode else { throw WorkspaceError.conflict }
        let control = CommandControl()
        let initial = CommandUpdate(proposal: proposal, output: "", result: nil, error: nil)
        commandHistory[id] = initial; commandOrder.append(id); onUpdate(initial)
        let task = Task.detached {
            try CommandProcess.run(proposal, directoryFD: directory, control: control, onOutput: {
                onUpdate(CommandUpdate(proposal: proposal, output: $0, result: nil, error: nil))
            })
        }
        runningCommands[id] = RunningCommand(proposal: proposal, control: control, task: task)
        defer { runningCommands[id] = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { control.cancel() }
            let final = CommandUpdate(proposal: proposal, output: result.output, result: result, error: nil)
            commandHistory[id] = final; onUpdate(final)
            return result
        } catch {
            let final = CommandUpdate(proposal: proposal, output: "", result: nil, error: error.localizedDescription)
            commandHistory[id] = final; onUpdate(final)
            throw error
        }
    }

    public func stopCommands() async {
        let active = runningCommands
        active.values.forEach { $0.control.cancel() }
        for (id, command) in active {
            switch await command.task.result {
            case .success(let result): commandHistory[id] = CommandUpdate(proposal: command.proposal, output: result.output, result: result, error: nil)
            case .failure(let error): commandHistory[id] = CommandUpdate(proposal: command.proposal, output: "", result: nil, error: error.localizedDescription)
            }
        }
    }

    public func completedCommands() -> [CommandUpdate] { commandOrder.compactMap { commandHistory[$0] } }

    // App-owned persistence is separate from all model-supplied workspace paths.
    nonisolated static func loadConfiguration(in directory: URL, filename: String = "config.json") throws -> Data? {
        try loadAppFile(named: filename, in: directory)
    }

    nonisolated static func saveConfiguration(_ data: Data, in directory: URL, filename: String = "config.json") throws {
        try saveAppFile(data, named: filename, in: directory)
    }

    nonisolated static func loadAppFile(named name: String, in directory: URL) throws -> Data? {
        do { return try Data(contentsOf: directory.appendingPathComponent(name)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    nonisolated static func saveAppFile(_ data: Data, named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Absolute URL for a path the app wants to hand to another program, such as
    /// Finder or the default editor. Validated exactly like tool access.
    public func url(for path: String) throws -> URL {
        try resolve(path)
    }

    private func resolve(_ path: String) throws -> URL {
        guard !path.utf8.contains(0), !path.split(separator: "/").contains("..") else {
            throw WorkspaceError.outsideWorkspace
        }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
            throw WorkspaceError.outsideWorkspace
        }
        return url
    }

    /// Walk with openat/O_NOFOLLOW so a symlink swap after validation cannot escape.
    private func openFile(_ path: String) throws -> Int32 {
        let url = try resolve(path)
        var descriptor = openat(rootDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.unreadable }
        let components = url.path.dropFirst(root.path == "/" ? 1 : root.path.count)
            .split(separator: "/")
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index < components.count - 1 ? O_DIRECTORY : 0)
            let next = openat(descriptor, String(component), flags)
            Darwin.close(descriptor)
            guard next >= 0 else { throw WorkspaceError.unreadable }
            descriptor = next
        }
        return descriptor
    }

    private func text(_ path: String) throws -> String {
        let descriptor = try openFile(path)
        defer { Darwin.close(descriptor) }
        return try text(descriptor: descriptor)
    }

    private func text(descriptor: Int32) throws -> String {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceError.unreadable
        }
        guard info.st_size <= 1_048_576 else { throw WorkspaceError.tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw WorkspaceError.tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.notText
        }
        return text
    }

    public func directoryEntries(path: String = ".") throws -> DirectoryListing {
        let folder = try resolve(path)
        let descriptor = try openFile(path)
        guard let directory = fdopendir(descriptor) else { Darwin.close(descriptor); throw WorkspaceError.unreadable }
        defer { closedir(directory) }
        let prefix = relative(folder)
        var entries: [WorkspaceEntry] = []
        var visited = 0
        while let entry = readdir(directory) {
            try Task.checkCancellation()
            visited += 1
            if visited > 2_000 { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard ![".", "..", ".git", ".lumen", ".build", "node_modules", "build"].contains(name) else { continue }
            var info = stat()
            guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { continue }
            entries.append(WorkspaceEntry(path: prefix.isEmpty ? name : prefix + "/" + name, name: name, isDirectory: kind == S_IFDIR))
        }
        entries.sort {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return DirectoryListing(entries: Array(entries.prefix(500)), truncated: visited > 2_000 || entries.count > 500)
    }

    private func relative(_ url: URL) -> String {
        url.path == root.path ? "" : String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }

    private func editTarget(_ path: String) throws -> (path: String, name: String, descriptor: Int32, info: stat) {
        let url = try resolve(path)
        let relativePath = relative(url)
        let protected = relativePath.split(separator: "/").contains {
            let name = $0.lowercased()
            return name == ".git" || name == ".lumen"
        }
        guard !relativePath.isEmpty, !protected else {
            throw WorkspaceError.protectedPath
        }
        let parent = url.deletingLastPathComponent()
        let descriptor = try openFile(parent.path)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor); throw WorkspaceError.unreadable
        }
        return (relativePath, url.lastPathComponent, descriptor, info)
    }

    private func existingText(parent: Int32, name: String) throws -> String? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw WorkspaceError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.unreadable }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.unreadable }
        defer { Darwin.close(descriptor) }
        return try text(descriptor: descriptor)
    }

    public func prepareEdit(path: String, oldText: String, newText: String) throws -> FileEditProposal {
        try Task.checkCancellation()
        guard !same(oldText, newText), !newText.utf8.contains(0), newText.utf8.count <= 1_048_576 else { throw WorkspaceError.invalidArguments }
        return try prepareReplacement(path: path) { before in
            if let before {
                guard !oldText.isEmpty, let range = before.range(of: oldText, options: .literal),
                      before.range(of: oldText, options: .literal, range: before.index(after: range.lowerBound)..<before.endIndex) == nil else { throw WorkspaceError.ambiguousEdit }
                return before.replacingCharacters(in: range, with: newText)
            }
            guard oldText.isEmpty else { throw WorkspaceError.ambiguousEdit }
            return newText
        }
    }

    /// Prepares a whole-file replacement for every operation in a patch. All
    /// files are validated before approval, so a bad hunk changes nothing.
    func preparePatch(_ patches: [FilePatch]) throws -> [FileEditProposal] {
        try Task.checkCancellation()
        guard !patches.isEmpty else { throw WorkspaceError.patch("The patch contains no file changes.") }
        var proposals: [FileEditProposal] = []
        var paths: Set<String> = []
        do {
            for patch in patches {
                let proposal = try prepareReplacement(path: patch.path) { before in
                    try patch.applying(to: before)
                }
                guard paths.insert(proposal.path).inserted else {
                    pending[proposal.id] = nil
                    throw WorkspaceError.patch("Each file may appear only once in a patch: \(proposal.path).")
                }
                proposals.append(proposal)
            }
        } catch {
            for proposal in proposals { pending[proposal.id] = nil }
            throw error
        }
        return proposals
    }

    private func prepareReplacement(path: String, transform: (String?) throws -> String?) throws -> FileEditProposal {
        try Task.checkCancellation()
        let target = try editTarget(path)
        defer { Darwin.close(target.descriptor) }
        let before = try existingText(parent: target.descriptor, name: target.name)
        let mode: UInt16?
        if before == nil {
            mode = nil
        } else {
            var info = stat()
            guard fstatat(target.descriptor, target.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkspaceError.unreadable }
            mode = UInt16(info.st_mode & 0o7777)
        }
        let after = try transform(before)
        guard !same(before, after) else { throw WorkspaceError.invalidArguments }
        if let after {
            guard !after.utf8.contains(0) else { throw WorkspaceError.invalidArguments }
            guard after.utf8.count <= 1_048_576 else { throw WorkspaceError.tooLarge }
        }
        let proposal = FileEditProposal(id: UUID(), path: target.path, before: before, after: after, mode: mode)
        pending[proposal.id] = PendingEdit(proposal: proposal, parentDevice: target.info.st_dev, parentInode: target.info.st_ino)
        return proposal
    }

    public func discardEdit(_ id: UUID) { pending[id] = nil }

    public func applyEdit(_ id: UUID) throws -> AppliedChange {
        try Task.checkCancellation()
        guard let edit = pending.removeValue(forKey: id) else { throw WorkspaceError.unknownProposal }
        let target = try editTarget(edit.proposal.path)
        defer { Darwin.close(target.descriptor) }
        guard target.info.st_dev == edit.parentDevice, target.info.st_ino == edit.parentInode,
              same(try existingText(parent: target.descriptor, name: target.name), edit.proposal.before) else { throw WorkspaceError.conflict }
        let backupPath = try snapshot(edit.proposal)
        try replace(parent: target.descriptor, name: target.name, expected: edit.proposal.before, content: edit.proposal.after, mode: edit.proposal.mode)
        let change = AppliedChange(proposal: edit.proposal, backupPath: backupPath)
        applied[id] = change
        appliedOrder.append(id)
        appliedParents[id] = (target.info.st_dev, target.info.st_ino)
        return change
    }

    public func appliedChanges() -> [AppliedChange] { appliedOrder.compactMap { applied[$0] } }

    public func undoEdit(_ id: UUID) throws {
        guard let change = applied[id] else { throw WorkspaceError.unknownProposal }
        try undoEdit(change)
    }

    /// Undoes a change restored from a saved chat, whose in-memory ledger is gone.
    /// The content check still refuses if the file no longer holds the applied text.
    public func undoEdit(_ change: AppliedChange) throws {
        try Task.checkCancellation()
        guard !change.undone else { throw WorkspaceError.unknownProposal }
        let target = try editTarget(change.proposal.path)
        defer { Darwin.close(target.descriptor) }
        if let parent = appliedParents[change.id],
           parent.device != target.info.st_dev || parent.inode != target.info.st_ino {
            throw WorkspaceError.conflict
        }
        guard same(try existingText(parent: target.descriptor, name: target.name), change.proposal.after) else {
            throw WorkspaceError.conflict
        }
        try replace(parent: target.descriptor, name: target.name, expected: change.proposal.after, content: change.proposal.before, mode: change.proposal.mode)
        applied[change.id]?.undone = true
    }

    private func snapshot(_ proposal: FileEditProposal) throws -> String {
        var directory = openat(rootDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw WorkspaceError.writeFailed }
        for name in [".lumen", "backups"] {
            if mkdirat(directory, name, 0o700) != 0, errno != EEXIST { Darwin.close(directory); throw WorkspaceError.writeFailed }
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(directory)
            guard next >= 0 else { throw WorkspaceError.writeFailed }
            directory = next
        }
        defer { Darwin.close(directory) }
        let name = proposal.id.uuidString + ".json"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.writeFailed }
        defer { Darwin.close(descriptor) }
        try write(JSONEncoder().encode(proposal), descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw WorkspaceError.writeFailed }
        return ".lumen/backups/" + name
    }

    private func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw WorkspaceError.writeFailed }
                offset += count
            }
        }
    }

    private func replace(parent: Int32, name: String, expected: String?, content: String?, mode: UInt16? = nil) throws {
        try Task.checkCancellation()
        guard same(try existingText(parent: parent, name: name), expected) else { throw WorkspaceError.conflict }
        let temporary = ".lumen-edit-" + UUID().uuidString
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.writeFailed }
        var keepTemporary = false
        defer {
            Darwin.close(descriptor)
            if !keepTemporary { unlinkat(parent, temporary, 0) }
        }
        if let content { try write(Data(content.utf8), descriptor: descriptor) }
        if expected == nil, let mode {
            guard fchmod(descriptor, mode_t(mode)) == 0 else { throw WorkspaceError.writeFailed }
        }
        if expected != nil {
            let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard source >= 0 else { throw WorkspaceError.writeFailed }
            defer { Darwin.close(source) }
            guard fcopyfile(source, descriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw WorkspaceError.writeFailed }
        }
        // Preserve permissions/ACLs/xattrs, but make the new contents visible to timestamp-based build tools.
        guard futimens(descriptor, nil) == 0 else { throw WorkspaceError.writeFailed }
        guard fsync(descriptor) == 0 else { throw WorkspaceError.writeFailed }
        try Task.checkCancellation()
        if expected == nil {
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? WorkspaceError.conflict : WorkspaceError.writeFailed
            }
        } else {
            // Swap retains the displaced file until it is checked, rather than blindly overwriting it.
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) == 0 else { throw WorkspaceError.writeFailed }
            let displaced = try? existingText(parent: parent, name: temporary)
            guard same(displaced, expected) else {
                // Preserve both versions if another writer also changed the newly installed file.
                if same(try? existingText(parent: parent, name: name), content ?? "") {
                    if renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) != 0 { keepTemporary = true }
                } else { keepTemporary = true }
                throw WorkspaceError.conflict
            }
            if content == nil {
                guard unlinkat(parent, name, 0) == 0 else { keepTemporary = true; throw WorkspaceError.writeFailed }
            }
            // Retain the actual displaced inode too, including late writes from an already-open editor.
            let backups = try? openFile(".lumen/backups")
            if let backups {
                defer { Darwin.close(backups) }
                if renameatx_np(parent, temporary, backups, UUID().uuidString + ".original", UInt32(RENAME_EXCL)) != 0 { keepTemporary = true }
            } else { keepTemporary = true }
        }
    }

    private func same(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case (let left?, let right?): left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    public func readFile(path: String, offset: Int = 1, limit: Int = 200) throws -> String {

        guard offset > 0, (1...500).contains(limit) else { throw WorkspaceError.invalidArguments }
        try Task.checkCancellation()
        let lines = try text(path).components(separatedBy: "\n")
        let start = min(offset - 1, lines.count)
        let end = start + min(limit, lines.count - start)
        let output = (start..<end).map { "\($0 + 1): \(lines[$0])" }.joined(separator: "\n")
        return bounded(output) + "\n[Lines \(start + 1)-\(end) of \(lines.count)]"
    }

    /// Reads a text file that may legitimately be absent, without line numbers or
    /// the read tools' bounds. Used for instruction files, so a missing or
    /// unreadable `AGENTS.md` is simply no instruction rather than an error.
    public func readOptionalText(path: String) throws -> String? {
        do { return try text(path) }
        catch WorkspaceError.unreadable { return nil }
        catch WorkspaceError.notText { return nil }
        catch WorkspaceError.tooLarge { return nil }
    }

    /// Whether the workspace root itself is a Git repository. The check looks only
    /// at the root, so a nested repository does not change the reported environment.
    public func hasGitDirectory() -> Bool {
        var info = stat()
        let present = fstatat(rootDescriptor, ".git", &info, AT_SYMLINK_NOFOLLOW) == 0
        return present && ((info.st_mode & S_IFMT) == S_IFDIR || (info.st_mode & S_IFMT) == S_IFREG)
    }

    private func files(path: String) throws -> (paths: [String], truncated: Bool) {
        let folder = try resolve(path)
        let descriptor = try openFile(path)
        var result: [String] = []
        var visited = 0
        var truncated = false
        func walk(_ descriptor: Int32, prefix: String, depth: Int) throws {
            guard let directory = fdopendir(descriptor) else {
                Darwin.close(descriptor)
                throw WorkspaceError.unreadable
            }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                try Task.checkCancellation()
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                guard !name.hasPrefix(".") else { continue }
                visited += 1
                if visited > 10_000 { truncated = true; return }
                var info = stat()
                guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw WorkspaceError.unreadable
                }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                if (info.st_mode & S_IFMT) == S_IFREG { result.append(relative) }
                else if (info.st_mode & S_IFMT) == S_IFDIR {
                    if ["node_modules", "build", "vendor"].contains(name) { continue }
                    guard depth < 64 else { truncated = true; continue }
                    let child = openat(dirfd(directory), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw WorkspaceError.unreadable }
                    try walk(child, prefix: relative, depth: depth + 1)
                    if visited > 10_000 { return }
                }
            }
        }
        let prefix = folder.path == root.path ? "" : String(folder.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
        try walk(descriptor, prefix: prefix, depth: 0)
        return (result.sorted(), truncated)
    }

    public func listFiles(path: String = ".") throws -> String {
        let result = try files(path: path)
        return bounded(result.paths.prefix(500).joined(separator: "\n"))
            + (result.truncated || result.paths.count > 500 ? "\n[File list truncated; narrow the path.]" : "")
    }

    public func search(query: String, path: String = ".") throws -> String {
        guard !query.isEmpty, query.count <= 500 else { throw WorkspaceError.invalidArguments }
        let result = try files(path: path)
        var matches: [String] = []
        var outputSize = 0
        var scannedBytes = 0
        // ponytail: bounded literal scan; use ripgrep through WorkspaceService if large repos need it.
        for file in result.paths {
            try Task.checkCancellation()
            let content: String
            do { content = try text(file) }
            catch WorkspaceError.notText { continue }
            catch WorkspaceError.tooLarge { continue }
            scannedBytes += content.utf8.count
            if scannedBytes > 33_554_432 {
                return bounded(matches.joined(separator: "\n")) + "\n[Search stopped at the 32 MB scan limit; narrow the path.]"
            }
            for (index, line) in content.components(separatedBy: "\n").enumerated() where line.contains(query) {
                let match = "\(file):\(index + 1): \(line.prefix(500))"
                matches.append(match)
                outputSize += match.count
                if matches.count >= 100 || outputSize >= 24_000 {
                    return bounded(matches.joined(separator: "\n")) + "\n[Search truncated; narrow the path or query.]"
                }
            }
        }
        return (matches.isEmpty ? "No matches." : matches.joined(separator: "\n"))
            + "\n[Literal search; hidden files, symlinks, build/vendor folders, binary and >1 MB files excluded.\(result.truncated ? " File scan truncated at 10,000 entries." : "")]"
    }

    private func bounded(_ text: String) -> String {
        text.count > 24_000 ? String(text.prefix(24_000)) + "\n[Output truncated]" : text
    }
}
