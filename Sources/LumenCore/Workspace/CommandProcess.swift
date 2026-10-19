import Darwin
import Foundation

public struct CommandProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let executable: String
    public let arguments: [String]
    public let directory: String
    public let timeoutSeconds: Int
    let executablePath: String
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let totalBytes: Int
    public let truncated: Bool
    public let timedOut: Bool
    public let cancelled: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

public struct CommandUpdate: Identifiable, Equatable, Sendable {
    public var id: UUID { proposal.id }
    public let proposal: CommandProposal
    public let output: String
    public let result: CommandResult?
    public let error: String?
    public var isRunning: Bool { result == nil && error == nil }
}

public enum CommandError: LocalizedError, Equatable {
    case invalidArguments, blocked, executableUnavailable, launchFailed(Int32), processFailed
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "Use a program name and an argument array; timeout must be 1–600 seconds. Shell expressions and inline code are not accepted."
        case .blocked: "This command or option is blocked by Lumen's command policy. Approval cannot override this restriction."
        case .executableUnavailable: "The program is not available in Lumen's trusted executable search path."
        case .launchFailed(let code): "The command could not be launched (OS error \(code))."
        case .processFailed: "The command could not be monitored safely. Its process group was terminated."
        }
    }
}

enum CommandPolicy {
    static let searchPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
    private static let blockedPrograms: Set<String> = [
        "sudo", "su", "doas", "rm", "rmdir", "dd", "mkfs", "newfs", "diskutil", "shutdown", "reboot",
        "launchctl", "security", "osascript", "csrutil", "chown", "kill", "pkill", "killall",
        "env", "xargs", "exec", "eval", "command", "nohup", "setsid", "ssh", "scp", "sftp", "nc", "ncat", "socat"
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "csh", "tcsh", "dash", "ksh"]
    static func isShell(_ name: String) -> Bool { shells.contains(name) }
    static func shellScriptIndex(_ name: String, arguments: [String]) -> Int {
        if name == "bash", Array(arguments.prefix(2)) == ["--noprofile", "--norc"] { return 2 }
        if name == "zsh", arguments.first == "-f" { return 1 }
        return 0
    }
    static func normalizedArguments(_ name: String, _ arguments: [String]) -> [String] {
        if name == "bash", shellScriptIndex(name, arguments: arguments) == 0 { return ["--noprofile", "--norc"] + arguments }
        if name == "zsh", shellScriptIndex(name, arguments: arguments) == 0 { return ["-f"] + arguments }
        return arguments
    }

    static func validate(executable: String, arguments: [String], timeout: Int) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !executable.isEmpty, executable.count <= 100,
              executable.unicodeScalars.allSatisfy(allowed.contains), arguments.count <= 100,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 32_768,
              arguments.allSatisfy({ !$0.utf8.contains(0) }), (1...600).contains(timeout) else {
            throw CommandError.invalidArguments
        }
        guard !blockedPrograms.contains(executable),
              !arguments.contains(where: { ["-c", "-e", "--eval", "--eval=", "-exec", "-execdir", "-delete"].contains($0) || $0.hasPrefix("--eval=") }) else {
            throw CommandError.blocked
        }
        if shells.contains(executable) {
            // Shells may run a project file, never an inline expression or an interactive session.
            let index = shellScriptIndex(executable, arguments: arguments)
            guard ["sh", "bash", "zsh"].contains(executable), arguments.indices.contains(index),
                  !arguments[index].hasPrefix("-"), !arguments[index].isEmpty else { throw CommandError.blocked }
        }
        if ["python", "python3", "node", "ruby", "perl", "php", "swift"].contains(where: executable.hasPrefix),
           arguments.contains(where: { $0.hasPrefix("-c") || $0.hasPrefix("-e") || $0.hasPrefix("--eval") }) { throw CommandError.blocked }
        if executable == "git" {
            guard !arguments.contains(where: { ["--hard", "--force", "-f", "-fd", "-fdx", "--no-verify"].contains($0) }),
                  !arguments.contains(where: { ["clean", "push", "config", "reset"].contains($0) }) else { throw CommandError.blocked }
        }
        if executable == "find", arguments.contains(where: { $0.hasPrefix("-exec") || $0 == "-delete" }) { throw CommandError.blocked }
    }

    static func resolveExecutable(_ name: String) throws -> String {
        for folder in searchPaths {
            let path = folder + "/" + name
            if access(path, X_OK) == 0 {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                var info = stat()
                guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                guard !blockedPrograms.contains(url.lastPathComponent) else { throw CommandError.blocked }
                return url.path
            }
        }
        throw CommandError.executableUnavailable
    }

    static func environment(home: String = NSHomeDirectory(), temporary: String = NSTemporaryDirectory()) -> [String: String] {
        // Construct, don't filter: no API keys, tokens, custom headers, agent sockets or startup hooks are inherited.
        var environment = ["PATH": searchPaths.joined(separator: ":"), "HOME": home, "TMPDIR": temporary,
                           "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1", "CI": "1"]
        let developer = "/Applications/Xcode.app/Contents/Developer"
        if access(developer, R_OK) == 0 { environment["DEVELOPER_DIR"] = developer }
        return environment
    }
}

struct CommandOutputBuffer {
    static let halfLimit = 16_384
    private var head = Data()
    private var tail = Data()
    private(set) var totalBytes = 0
    var truncated: Bool { totalBytes > Self.halfLimit * 2 }

    mutating func append(_ data: Data) {
        totalBytes += data.count
        let headCount = min(data.count, Self.halfLimit - head.count)
        head.append(data.prefix(headCount))
        tail.append(data.dropFirst(headCount))
        if tail.count > Self.halfLimit { tail = Data(tail.suffix(Self.halfLimit)) }
    }

    var text: String {
        let marker = truncated ? "\n\n[\(totalBytes - Self.halfLimit * 2) output bytes omitted; showing head and tail]\n\n" : ""
        let text = String(decoding: head, as: UTF8.self) + marker + String(decoding: tail, as: UTF8.self)
        return text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Cancellation and PID retirement share a lock, so Stop cannot signal a reused PID.
final class CommandControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var stopped = false
    var isCancelled: Bool { lock.withLock { stopped } }

    func install(_ pid: pid_t) {
        lock.withLock { self.pid = pid; if stopped { Darwin.kill(-pid, SIGKILL) } }
    }
    func cancel() {
        lock.withLock { stopped = true; if let pid { Darwin.kill(-pid, SIGKILL) } }
    }
    func retire() {
        lock.withLock {
            if let pid { Darwin.kill(-pid, SIGKILL) }
            pid = nil
        }
    }
}

enum CommandProcess {
    static func run(_ proposal: CommandProposal, directoryFD: Int32, control: CommandControl,
                    onOutput: @Sendable (String) -> Void) throws -> CommandResult {
        var output = CommandOutputBuffer()
        if control.isCancelled { return result(output, status: 130 << 8, timedOut: false, cancelled: true) }
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw CommandError.processFailed }
        defer { Darwin.close(pipeFDs[0]); if pipeFDs[1] >= 0 { Darwin.close(pipeFDs[1]) } }
        guard fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC) == 0 else { throw CommandError.processFailed }

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw CommandError.processFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CommandError.processFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_addfchdir_np(&actions, directoryFD) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO) == 0 else { throw CommandError.processFailed }
        var pid: pid_t = 0
        let environment = CommandPolicy.environment().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let launch = try withCStrings([proposal.executablePath] + proposal.arguments) { argv in
            try withCStrings(environment) { env in
                posix_spawn(&pid, proposal.executablePath, &actions, &attributes, argv, env)
            }
        }
        guard launch == 0 else { throw CommandError.launchFailed(launch) }
        control.install(pid)
        Darwin.close(pipeFDs[1]); pipeFDs[1] = -1
        let start = ProcessInfo.processInfo.systemUptime
        var lastUpdate = start - 1
        var timedOut = false, eof = false, monitoringFailed = false
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now - start >= Double(proposal.timeoutSeconds), !timedOut {
                timedOut = true
                control.retire() // Terminate descendants as well as the leader.
            }
            var descriptor = pollfd(fd: eof ? -1 : pipeFDs[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0, errno != EINTR { monitoringFailed = true; break }
            if ready > 0, !eof {
                let count = Darwin.read(pipeFDs[0], &bytes, bytes.count)
                if count > 0 { output.append(Data(bytes.prefix(count))) }
                else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { monitoringFailed = true; break }
            }
            if now - lastUpdate >= 0.1 { onOutput(output.text); lastUpdate = now }
            var info = siginfo_t()
            // Observe without reaping: the process-group identifier cannot be reused before retirement.
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
                if errno == EINTR { continue }
                monitoringFailed = true; break
            }
            if info.si_pid == pid { break }
        }
        control.retire()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { monitoringFailed = true; break }
        }
        // All ordinary group members are stopped. Bound draining even if hostile code detached itself.
        for _ in 0..<64 {
            let count = Darwin.read(pipeFDs[0], &bytes, bytes.count)
            guard count > 0 else { break }
            output.append(Data(bytes.prefix(count)))
        }
        if monitoringFailed { throw CommandError.processFailed }
        return result(output, status: status, timedOut: timedOut, cancelled: control.isCancelled)
    }

    private static func result(_ output: CommandOutputBuffer, status: Int32, timedOut: Bool, cancelled: Bool) -> CommandResult {
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandResult(exitCode: code, output: output.text, totalBytes: output.totalBytes, truncated: output.truncated,
                             timedOut: timedOut, cancelled: cancelled)
    }

    private static func withCStrings<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        let allocated = strings.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else { throw CommandError.processFailed }
        var pointers = allocated + [nil]
        return try pointers.withUnsafeMutableBufferPointer {
            guard let base = $0.baseAddress else { throw CommandError.processFailed }
            return try body(base)
        }
    }
}
