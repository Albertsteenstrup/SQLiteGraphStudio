import Darwin
import Foundation

/// Subprocesses use files for output, so a full pipe cannot deadlock a restore.
/// Each tool owns a process group and tracks descendants that create new sessions.
/// Cancellation is remembered even if it arrives before spawning.
final class PostgresToolProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exitStatus: Int32?
    private struct Identity: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
        init(_ info: proc_bsdinfo) {
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }
    }
    private var ownedProcesses: [pid_t: Identity] = [:]
    private var trackingComplete = true
    private let arguments: [String]
    private let launchPath: String
    private let supervisesServer: Bool
    private let listChildren: @Sendable (pid_t, UnsafeMutableRawPointer?, Int32) -> Int32
    private let environment: [String]
    private let directory: URL
    private var cancelled = false
    private let output: URL
    private let toolName: String

    init(executable: URL, arguments: [String], directory: URL, profile: String, superviseParent: Bool = false,
         listChildren: @escaping @Sendable (pid_t, UnsafeMutableRawPointer?, Int32) -> Int32 = {
             proc_listpids(UInt32(PROC_PPID_ONLY), UInt32($0), $1, $2)
         }) {
        output = directory.appendingPathComponent("tool-\(UUID()).log")
        self.directory = directory
        toolName = executable.lastPathComponent
        supervisesServer = superviseParent
        self.listChildren = listChildren
        if superviseParent {
            // Resolved and validated in start(), which can report an error.
            launchPath = ""
            self.arguments = [PostgresRuntimeSupervisor.argument, String(ProcessInfo.processInfo.processIdentifier),
                directory.path, profile, executable.path] + arguments
        } else {
            launchPath = "/usr/bin/sandbox-exec"
            self.arguments = ["/usr/bin/sandbox-exec", "-p", profile, executable.path] + arguments
        }
        // Do not inherit PGOPTIONS, credentials, libpq service files or shell startup configuration.
        environment = ["PATH=/usr/bin:/bin", "LC_ALL=C", "HOME=\(directory.path)",
                       "TMPDIR=\(directory.path)", "PGCONNECT_TIMEOUT=2"]
    }

    func start() throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard pid == 0 else { throw DatabaseUserError(kind: .generic, message: "PostgreSQL tool already started.") }
            let executable = try supervisesServer ? PostgresRuntimeSupervisor.executable().path : launchPath
            var attributes: posix_spawnattr_t?
            var actions: posix_spawn_file_actions_t?
            func check(_ status: Int32) throws {
                if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
            }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
            try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))
            let commandArguments = supervisesServer ? [executable] + arguments : arguments
            var argv = commandArguments.map { strdup($0) } + [nil]
            var envp = environment.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            try argv.withUnsafeMutableBufferPointer { args in
                try envp.withUnsafeMutableBufferPointer { env in
                    try check(posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!))
                }
            }
            if let info = Self.processInfo(pid) { ownedProcesses[pid] = Identity(info) }
            else { trackingComplete = false }
        }
    }

    private static func processInfo(_ process: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        return proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func auditToken(_ process: pid_t) -> audit_token_t? {
        var port: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, process, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? token : nil
    }

    // Lock held. Keep start times, not just PIDs: never signal a recycled PID.
    // Discover before any signal can orphan a worker, and throughout shutdown.
    private func discoverDescendants() {
        var pending = Array(ownedProcesses.keys)
        var visited: Set<pid_t> = []
        while let parent = pending.popLast() {
            guard visited.insert(parent).inserted else { continue }
            guard let info = Self.processInfo(parent) else {
                if errno != ESRCH { trackingComplete = false }
                continue
            }
            guard Identity(info) == ownedProcesses[parent] else { continue }
            var capacity = 64
            while true {
                var children = [pid_t](repeating: 0, count: capacity)
                errno = 0
                let bytes = children.withUnsafeMutableBytes {
                    listChildren(parent, $0.baseAddress, Int32($0.count))
                }
                // libproc returns zero (not -1) on an underlying syscall error.
                guard bytes >= 0, bytes != 0 || errno == 0 else { trackingComplete = false; break }
                if Int(bytes) == capacity * MemoryLayout<pid_t>.size {
                    guard capacity < 65_536 else { trackingComplete = false; break }
                    capacity *= 2
                    continue
                }
                for child in children.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where child > 0 {
                    guard let childInfo = Self.processInfo(child) else {
                        if errno != ESRCH { trackingComplete = false }
                        continue
                    }
                    guard childInfo.pbi_ppid == UInt32(parent) else { continue }
                    guard let currentParent = Self.processInfo(parent) else {
                        trackingComplete = false
                        continue
                    }
                    guard Identity(currentParent) == ownedProcesses[parent] else { continue }
                    ownedProcesses[child] = Identity(childInfo)
                    pending.append(child)
                }
                break
            }
        }
    }

    private func ownedProcessIsRunning(_ process: pid_t, identity: Identity) -> Bool {
        guard let info = Self.processInfo(process) else {
            return Darwin.kill(process, 0) == 0 || errno != ESRCH
        }
        return Identity(info) == identity && info.pbi_status != SZOMB
    }

    private func reapIfExited() {
        guard pid > 0, exitStatus == nil else { return }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            // If the server supervisor dies before requested cleanup, current
            // ancestry can no longer prove that every backend was discovered.
            exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            if supervisesServer && (!cancelled || exitStatus != 0) { trackingComplete = false }
        }
    }

    var isRunning: Bool { lock.withLock { discoverDescendants(); reapIfExited(); return pid > 0 && exitStatus == nil } }

    private var ownedProcessesAreRunning: Bool {
        lock.withLock {
            discoverDescendants()
            reapIfExited()
            return ownedProcesses.contains { ownedProcessIsRunning($0.key, identity: $0.value) }
        }
    }

    func cancel(signal: Int32 = SIGTERM) {
        lock.withLock {
            // Observe an already-dead supervisor before marking this as a
            // requested shutdown; otherwise a first-observer cancel hides loss
            // of ancestry and could incorrectly authorize workspace deletion.
            reapIfExited()
            cancelled = true
            discoverDescendants()
            for (process, identity) in ownedProcesses {
                guard let info = Self.processInfo(process), Identity(info) == identity, info.pbi_status != SZOMB else { continue }
                guard var token = Self.auditToken(process) else { trackingComplete = false; continue }
                guard let current = Self.processInfo(process), Identity(current) == identity else { continue }
                // The kernel checks the token's PID version atomically with the
                // signal. Never fall back to kill(pid) after an identity failure.
                let result = proc_signal_with_audittoken(&token, signal)
                if result != 0 && result != ESRCH { trackingComplete = false }
            }
        }
    }

    func outputText() -> String {
        guard let handle = try? FileHandle(forReadingFrom: output) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 12_000 ? size - 12_000 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    func wait(timeout: TimeInterval = 600) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        return try await withTaskCancellationHandler {
            do {
                while isRunning {
                    try Task.checkCancellation()
                    guard Date() < deadline else {
                        throw DatabaseUserError(kind: .timeout, message: "Preparing the PostgreSQL backup timed out.")
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                let status = lock.withLock { exitStatus ?? -1 }
                guard status == 0 else {
                    throw DatabaseUserError(kind: .generic, message: "Could not prepare the PostgreSQL backup (\(toolName), exit \(status)).",
                                            recoverySuggestion: outputText())
                }
                return outputText()
            } catch {
                await stop()
                throw error
            }
        } onCancel: { self.cancel() }
    }

    @discardableResult func stop() async -> Bool {
        cancel(signal: SIGINT)
        // Cleanup must still run when the opening task itself has been cancelled.
        return await Task.detached {
            let deadline = Date().addingTimeInterval(5)
            while self.ownedProcessesAreRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            // PostgreSQL's immediate shutdown asks the postmaster to terminate
            // and reap its workers, including workers with their own sessions.
            if self.ownedProcessesAreRunning { self.cancel(signal: SIGQUIT) }
            let immediateDeadline = Date().addingTimeInterval(2)
            while self.ownedProcessesAreRunning && Date() < immediateDeadline { try? await Task.sleep(for: .milliseconds(50)) }
            if self.ownedProcessesAreRunning {
                // Freeze known ancestors before rescanning so escalation cannot
                // race with ordinary backend/worker creation.
                self.cancel(signal: SIGSTOP)
                self.cancel(signal: SIGSTOP)
                self.cancel(signal: SIGKILL)
            }
            let killDeadline = Date().addingTimeInterval(2)
            while self.ownedProcessesAreRunning && Date() < killDeadline { try? await Task.sleep(for: .milliseconds(20)) }
            return !self.ownedProcessesAreRunning && self.lock.withLock { self.trackingComplete }
        }.value
    }
}
