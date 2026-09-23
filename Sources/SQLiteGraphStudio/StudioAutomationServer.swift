import Darwin
import Foundation

/// Private, same-user socket used by the bundled stdio MCP helper. The socket is
/// intentionally not an HTTP listener and is unavailable to other local users.
final class StudioAutomationServer: @unchecked Sendable {
    typealias CallHandler = @MainActor @Sendable (
        _ toolName: String, _ arguments: Data, _ contextID: String?, _ clientID: String
    ) async -> Data
    typealias ClientDisconnectHandler = @MainActor @Sendable (_ clientID: String) async -> Void

    private let directory: URL
    private let socketURL: URL
    private let tokenURL: URL
    private let lockURL: URL
    private let token: String
    private let handler: CallHandler
    private let clientDisconnectHandler: ClientDisconnectHandler
    private let capabilities: [String]
    private let lock = NSLock()
    private var listeningSocket: Int32 = -1
    private static let maximumRequestBytes = 1_048_576

    init(
        directoryURL: URL? = nil,
        capabilities: [String],
        handler: @escaping CallHandler,
        clientDisconnectHandler: @escaping ClientDisconnectHandler = { _ in }
    ) {
        let base = directoryURL ?? URL(fileURLWithPath: "/tmp/sgs-mcp-\(getuid())", isDirectory: true)
        directory = base
        socketURL = base.appendingPathComponent("automation.sock")
        tokenURL = base.appendingPathComponent("instance.token")
        lockURL = base.appendingPathComponent("startup.lock")
        token = UUID().uuidString + UUID().uuidString
        self.capabilities = capabilities
        self.handler = handler
        self.clientDisconnectHandler = clientDisconnectHandler
    }

    func start() throws {
        try preparePrivateDirectory()
        let startupLock = try acquireStartupLock()
        defer { releaseStartupLock(startupLock) }
        if FileManager.default.fileExists(atPath: socketURL.path) {
            guard !anotherListenerIsRunning() else {
                throw SocketError("Another Graph Studio instance already owns the local MCP socket.")
            }
            try FileManager.default.removeItem(at: socketURL)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("Could not create local MCP socket: \(errno)") }
        var ownsSocketPath = false
        do {
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            var address = try makeAddress(socketURL.path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                throw SocketError("Could not bind the private MCP socket: \(errno)")
            }
            ownsSocketPath = true
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                throw SocketError("Could not protect the private MCP socket: \(errno)")
            }
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
            guard Darwin.chmod(tokenURL.path, 0o600) == 0 else {
                throw SocketError("Could not protect the MCP instance credential: \(errno)")
            }
            guard Darwin.listen(fd, 8) == 0 else {
                throw SocketError("Could not listen on the private MCP socket: \(errno)")
            }
        } catch {
            _ = Darwin.close(fd)
            if ownsSocketPath { try? FileManager.default.removeItem(at: socketURL) }
            throw error
        }

        lock.lock()
        listeningSocket = fd
        lock.unlock()
        Task.detached(priority: .utility) { [self] in await acceptConnections(on: fd) }
    }

    func stop() {
        let startupLock = try? acquireStartupLock()
        defer { if let startupLock { releaseStartupLock(startupLock) } }
        lock.lock()
        let fd = listeningSocket
        listeningSocket = -1
        lock.unlock()
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        // If the lock is unavailable, close our listener but leave shared path
        // cleanup to the next successful startup rather than unlink a peer.
        guard startupLock != nil else { return }
        try? FileManager.default.removeItem(at: socketURL)
        try? FileManager.default.removeItem(at: tokenURL)
    }

    private func preparePrivateDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            let result = Darwin.mkdir(directory.path, 0o700)
            guard result == 0 || errno == EEXIST else {
                throw SocketError("Could not create the private MCP directory: \(errno)")
            }
        }
        var statInfo = stat()
        guard lstat(directory.path, &statInfo) == 0,
              (statInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              statInfo.st_uid == getuid(),
              (statInfo.st_mode & 0o077) == 0 else {
            throw SocketError("The local MCP directory must be owned by this user and private: \(directory.path)")
        }
    }

    private func acquireStartupLock() throws -> Int32 {
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SocketError("Could not open the local MCP startup lock: \(errno)") }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              flock(fd, LOCK_EX) == 0 else {
            _ = Darwin.close(fd)
            throw SocketError("The local MCP startup lock is not private or could not be acquired.")
        }
        return fd
    }

    private func releaseStartupLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
    }

    private func anotherListenerIsRunning() -> Bool {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return true }
        defer { _ = Darwin.close(probe) }
        guard var address = try? makeAddress(socketURL.path) else { return true }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError("The local MCP socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes)
        }
        return address
    }

    private func acceptConnections(on fd: Int32) async {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                _ = Darwin.close(client)
                continue
            }
            Task.detached(priority: .utility) { [self] in await handle(client) }
        }
    }

    private func handle(_ client: Int32) async {
        defer { _ = Darwin.close(client) }
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = bytes.withUnsafeMutableBytes { target in
                Darwin.recv(client, target.baseAddress, target.count, 0)
            }
            guard count > 0 else { return }
            pending.append(contentsOf: bytes[..<count])
            guard pending.count <= Self.maximumRequestBytes else { return }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                let response = await reply(to: line)
                guard writeAll(response + Data([10]), to: client) else { return }
            }
        }
    }

    private func reply(to line: Data) async -> Data {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return jsonRPC(id: NSNull(), error: [-32600, "Invalid JSON-RPC request"])
        }
        let id = request["id"] ?? NSNull()
        guard let params = request["params"] as? [String: Any],
              params["credential"] as? String == token else {
            return jsonRPC(id: id, error: [-32001, "Local MCP authentication failed"])
        }
        if method == "bridge/hello" {
            guard params["protocolVersion"] as? Int == 1,
                  params["clientId"] as? String != nil else {
                return jsonRPC(id: id, error: [-32602, "Unsupported bridge handshake"])
            }
            return jsonRPC(id: id, result: [
                "protocolVersion": 1,
                "appInstanceId": token.prefix(12).description,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                "appBundlePath": Bundle.main.bundleURL.standardizedFileURL.path,
                "capabilities": capabilities,
            ])
        }
        if method == "bridge/client-disconnected" {
            guard let clientID = params["clientId"] as? String, !clientID.isEmpty else {
                return jsonRPC(id: id, error: [-32602, "Client disconnect requires a client ID"])
            }
            await clientDisconnectHandler(clientID)
            return jsonRPC(id: id, result: ["released": true])
        }
        guard method == "automation/call",
              let name = params["toolName"] as? String,
              let clientID = params["clientId"] as? String,
              let arguments = params["arguments"] as? [String: Any],
              let argumentsData = try? JSONSerialization.data(withJSONObject: arguments) else {
            return jsonRPC(id: id, error: [-32602, "Invalid automation call"])
        }
        let resultData = await handler(name, argumentsData, params["contextId"] as? String, clientID)
        guard let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return jsonRPC(id: id, error: [-32603, "The app returned invalid tool content"])
        }
        return jsonRPC(id: id, result: result)
    }

    private func jsonRPC(id: Any, result: Any? = nil, error: [Any]? = nil) -> Data {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { message["result"] = result }
        if let error { message["error"] = ["code": error[0], "message": error[1]] }
        return (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func writeAll(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let count = Darwin.send(socket, base.advanced(by: written), raw.count - written, 0)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }

    private struct SocketError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
