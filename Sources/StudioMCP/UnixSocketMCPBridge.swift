import AppKit
import Darwin
import Foundation

public protocol MCPBridgeTransport {
    func status(clientID: String) -> [String: Any]
    func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any]
    func call(_ call: MCPToolCall, contextID: String?) -> [String: Any]
    func disconnect(clientID: String)
}

public extension MCPBridgeTransport {
    func disconnect(clientID: String) {}
}

public final class LocalMCPToolDispatcher: MCPToolDispatcher {
    private let transport: MCPBridgeTransport

    public init(transport: MCPBridgeTransport = UnixSocketMCPBridge()) {
        self.transport = transport
    }

    public func clientDisconnected(clientID: String) {
        transport.disconnect(clientID: clientID)
    }

    public func dispatch(_ call: MCPToolCall) -> [String: Any] {
        switch call.name {
        case "studio_status":
            return transport.status(clientID: call.clientID)
        case "studio_launch":
            let wait = call.arguments["wait_ms"] as? Int ?? call.arguments["wait_timeout_ms"] as? Int ?? 10_000
            let foreground = call.arguments["foreground_intent"] as? Bool
                ?? call.arguments["foreground"] as? Bool
                ?? true
            return transport.launch(
                clientID: call.clientID,
                timeoutMilliseconds: min(max(wait, 1_000), 30_000),
                foreground: foreground
            )
        default:
            var arguments = call.arguments
            if call.name == "studio_connect_context", arguments["project_path"] == nil {
                arguments["project_path"] = call.workingDirectory
            }
            // A single client process can serve more than one coding task.
            // Every app-bound call must carry the exact task context rather
            // than inheriting whichever task connected most recently.
            let contextID = call.contextID
            let routedCall = MCPToolCall(
                name: call.name,
                arguments: arguments,
                contextID: contextID,
                clientID: call.clientID,
                clientName: call.clientName,
                clientVersion: call.clientVersion,
                workingDirectory: call.workingDirectory
            )
            let result = transport.call(routedCall, contextID: contextID)
            return result
        }
    }
}

public final class UnixSocketMCPBridge: MCPBridgeTransport {
    private let launchApplication: (URL, Bool) throws -> Void
    private let sleep: (TimeInterval) -> Void
    private let applicationURLProvider: () -> URL?

    public convenience init() {
        self.init(
            launchApplication: { try Self.openApplication($0, foreground: $1) },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            applicationURLProvider: { Self.findApplication() }
        )
    }

    public init(
        launchApplication: @escaping (URL, Bool) throws -> Void,
        sleep: @escaping (TimeInterval) -> Void,
        applicationURLProvider: @escaping () -> URL?
    ) {
        self.launchApplication = launchApplication
        self.sleep = sleep
        self.applicationURLProvider = applicationURLProvider
    }

    public func status(clientID: String) -> [String: Any] {
        let appURL = applicationURLProvider()
        let runningCopies = NSRunningApplication.runningApplications(
            withBundleIdentifier: MCPBridgePaths.appBundleIdentifier
        )
        let isRunning = runningCopies.contains { runningApplication in
            guard let appURL, let runningURL = runningApplication.bundleURL else { return false }
            return runningURL.resolvingSymlinksInPath().standardizedFileURL ==
                appURL.resolvingSymlinksInPath().standardizedFileURL
        }
        let preferredURL = appURL?.resolvingSymlinksInPath().standardizedFileURL
        let otherCopyRunning = runningCopies.contains { runningApplication in
            guard let runningURL = runningApplication.bundleURL else { return true }
            return runningURL.resolvingSymlinksInPath().standardizedFileURL != preferredURL
        }
        let handshake: [String: Any]?
        let diagnostic: String?
        do {
            handshake = try withAuthenticatedConnection(clientID: clientID) { connection in
                try verifiedHandshake(connection)
            }
            diagnostic = nil
        } catch let error as MCPBridgeError {
            handshake = nil
            diagnostic = error.message
        } catch {
            handshake = nil
            diagnostic = "The local app bridge could not be checked."
        }

        var state: [String: Any] = [
            "appInstalled": appURL != nil,
            "appRunning": isRunning,
            "otherCopyRunning": otherCopyRunning,
            "bridgeConnected": handshake != nil,
            "bridgeDiagnostic": diagnostic.map { $0 as Any } ?? NSNull(),
            "clientId": clientID,
            "protocolVersions": MCPServer.supportedProtocolVersions,
            "toolCount": MCPToolCatalog.tools.count,
            "capabilities": ["status": true, "launch": true, "appAutomation": handshake != nil],
        ]
        if let handshake {
            state["appInstanceId"] = handshake["appInstanceId"] ?? NSNull()
            state["appVersion"] = handshake["appVersion"] ?? NSNull()
            state["appCapabilities"] = handshake["capabilities"] ?? []
        }

        let summary: String
        if handshake != nil {
            summary = otherCopyRunning
                ? "This Graph Studio copy is accepting local MCP requests; another copy is also running."
                : "Graph Studio is running and accepting local MCP requests."
        } else if isRunning && otherCopyRunning {
            summary = "This Graph Studio copy and another copy are running, but this copy's local MCP bridge is not ready."
        } else if isRunning {
            summary = "Graph Studio is running, but its local MCP bridge is not ready."
        } else if otherCopyRunning {
            summary = "A different Graph Studio copy is running. This helper's app is closed; ask before opening it or closing the other copy."
        } else if appURL != nil {
            summary = "Graph Studio is installed and closed. This status check did not launch it."
        } else {
            summary = "Graph Studio is not installed at a discoverable application location."
        }
        return makeToolResult(summary: summary, structuredContent: state)
    }

    public func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any] {
        guard let appURL = applicationURLProvider() else {
            return errorResult(
                code: "APP_NOT_INSTALLED",
                message: "SQLite Graph Studio could not be found. Install it in /Applications or ~/Applications, then retry."
            )
        }

        let runningCopies = NSRunningApplication.runningApplications(
            withBundleIdentifier: MCPBridgePaths.appBundleIdentifier
        )
        let pairedCopyRunning = runningCopies.contains {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL ==
                appURL.resolvingSymlinksInPath().standardizedFileURL
        }
        if !pairedCopyRunning && runningCopies.contains(where: {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL !=
                appURL.resolvingSymlinksInPath().standardizedFileURL
        }) {
            return errorResult(
                code: "APP_INSTANCE_MISMATCH",
                message: "A different Graph Studio copy is running. Close it before launching this helper's app."
            )
        }

        do {
            try launchApplication(appURL, foreground)
        } catch {
            return errorResult(
                code: "APP_LAUNCH_FAILED",
                message: "SQLite Graph Studio could not be opened: \(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        var lastError: MCPBridgeError?
        while Date() < deadline {
            do {
                let handshake = try withAuthenticatedConnection(clientID: clientID) { connection in
                    try verifiedHandshake(connection)
                }
                return makeToolResult(
                    summary: "SQLite Graph Studio is open and its local MCP bridge is ready.",
                    structuredContent: [
                        "launched": true,
                        "ready": true,
                        "appInstanceId": handshake["appInstanceId"] ?? NSNull(),
                        "appVersion": handshake["appVersion"] ?? NSNull(),
                        "capabilities": handshake["capabilities"] ?? [],
                    ]
                )
            } catch let error as MCPBridgeError {
                if error.code == "APP_INSTANCE_MISMATCH" {
                    return errorResult(code: error.code, message: error.message)
                }
                lastError = error
            } catch {
                lastError = MCPBridgeError(code: "APP_BRIDGE_ERROR", message: "The app bridge did not become ready.")
            }
            sleep(0.1)
        }
        return errorResult(
            code: "APP_BRIDGE_TIMEOUT",
            message: "SQLite Graph Studio opened, but its local MCP bridge did not become ready before the timeout.",
            extra: ["diagnostic": lastError?.message ?? "No bridge response was received."]
        )
    }

    public func call(_ call: MCPToolCall, contextID: String?) -> [String: Any] {
        do {
            return try withAuthenticatedConnection(
                clientID: call.clientID,
                timeoutSeconds: requestTimeoutSeconds(for: call)
            ) { connection in
                _ = try verifiedHandshake(connection)
                var arguments = call.arguments
                if let contextID, arguments["context_id"] == nil {
                    arguments["context_id"] = contextID
                }
                var params: [String: Any] = [
                    "credential": connection.credential,
                    "clientId": call.clientID,
                    "toolName": call.name,
                    "arguments": arguments,
                    "clientInfo": [
                        "name": call.clientName ?? "Unknown MCP client",
                        "version": call.clientVersion ?? "unknown",
                    ],
                    "workingDirectory": call.workingDirectory,
                ]
                if let contextID {
                    params["contextId"] = contextID
                }
                let response = try connection.request(
                    method: "automation/call",
                    params: params,
                    id: UUID().uuidString.lowercased()
                )
                if let error = response["error"] as? [String: Any] {
                    let data = error["data"] as? [String: Any] ?? [:]
                    return errorResult(
                        code: data["code"] as? String ?? "APP_AUTOMATION_ERROR",
                        message: error["message"] as? String ?? "The app could not handle this tool request.",
                        extra: data
                    )
                }
                guard let result = response["result"] as? [String: Any],
                      result["content"] is [[String: Any]]
                else {
                    return errorResult(
                        code: "APP_PROTOCOL_ERROR",
                        message: "The app returned an invalid MCP tool result."
                    )
                }
                return result
            }
        } catch let error as MCPBridgeError {
            return errorResult(code: error.code, message: error.message)
        } catch {
            return errorResult(code: "APP_BRIDGE_ERROR", message: "The local app bridge request failed.")
        }
    }

    public func disconnect(clientID: String) {
        do {
            try withAuthenticatedConnection(clientID: clientID) { connection in
                _ = try verifiedHandshake(connection)
                let response = try connection.request(
                    method: "bridge/client-disconnected",
                    params: ["credential": connection.credential, "clientId": clientID],
                    id: UUID().uuidString.lowercased()
                )
                if response["error"] != nil {
                    throw MCPBridgeError(
                        code: "APP_BRIDGE_ERROR",
                        message: "The app could not release this MCP client's state."
                    )
                }
            }
        } catch {
            // Stdio may close while the app is quitting or unavailable. Cleanup
            // is best-effort and must never keep the coding client alive.
        }
    }

    private func withAuthenticatedConnection<T>(
        clientID: String,
        timeoutSeconds: Int = 5,
        operation: (AuthenticatedSocket) throws -> T
    ) throws -> T {
        let credential = try loadCredential()
        let socketFD = try connectSocket(timeoutSeconds: timeoutSeconds)
        defer { Darwin.close(socketFD) }
        let connection = AuthenticatedSocket(fileDescriptor: socketFD, credential: credential, clientID: clientID)
        return try operation(connection)
    }

    private func verifiedHandshake(_ connection: AuthenticatedSocket) throws -> [String: Any] {
        let handshake = try connection.handshake()
        guard let expected = applicationURLProvider()?.resolvingSymlinksInPath().standardizedFileURL,
              let remotePath = handshake["appBundlePath"] as? String,
              URL(fileURLWithPath: remotePath).resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw MCPBridgeError(
                code: "APP_INSTANCE_MISMATCH",
                message: "Another Graph Studio copy owns the local MCP endpoint. Close that copy and open this helper's app."
            )
        }
        return handshake
    }

    private func requestTimeoutSeconds(for call: MCPToolCall) -> Int {
        let waitMilliseconds: Int?
        switch call.name {
        case "studio_wait_events": waitMilliseconds = call.arguments["wait_ms"] as? Int
        case "studio_run_query": waitMilliseconds = call.arguments["timeout_ms"] as? Int
        default: waitMilliseconds = nil
        }
        let budget = waitMilliseconds ?? 25_000
        return min(max((max(budget, 0) + 999) / 1_000 + 5, 5), 65)
    }

    private func loadCredential() throws -> String {
        try validateOwnedPath(MCPBridgePaths.runtimeDirectory.path, kind: .directory, requiredMode: 0o700)
        try validateOwnedPath(MCPBridgePaths.credentialURL.path, kind: .regularFile, requiredMode: 0o600)
        let data: Data
        do {
            data = try Data(contentsOf: MCPBridgePaths.credentialURL)
        } catch {
            throw MCPBridgeError(code: "APP_NOT_RUNNING", message: "The app instance credential is unavailable.")
        }
        let credential = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isTokenCharacter: (UInt8) -> Bool = { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
        }
        guard credential.count >= 32, credential.utf8.allSatisfy(isTokenCharacter) else {
            throw MCPBridgeError(code: "APP_BRIDGE_UNAVAILABLE", message: "The app instance credential is invalid.")
        }
        return credential
    }

    private func connectSocket(timeoutSeconds: Int) throws -> Int32 {
        try validateOwnedPath(MCPBridgePaths.socketURL.path, kind: .socket, requiredMode: 0o600)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPBridgeError(code: "APP_BRIDGE_UNAVAILABLE", message: "Could not open the local app socket.")
        }

        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        let path = MCPBridgePaths.socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw MCPBridgeError(code: "APP_BRIDGE_CONFIGURATION_ERROR", message: "The local app socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }

        let connectStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectStatus == 0 else {
            let code = errno == ENOENT || errno == ECONNREFUSED ? "APP_NOT_RUNNING" : "APP_BRIDGE_UNAVAILABLE"
            Darwin.close(fd)
            throw MCPBridgeError(code: code, message: "The Graph Studio local MCP socket is not accepting connections.")
        }

        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            Darwin.close(fd)
            throw MCPBridgeError(code: "APP_BRIDGE_UNTRUSTED", message: "The local socket peer does not belong to this user.")
        }
        return fd
    }

    private func validateOwnedPath(_ path: String, kind: OwnedPathKind, requiredMode: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno == ENOENT ? "APP_NOT_RUNNING" : "APP_BRIDGE_UNAVAILABLE"
            throw MCPBridgeError(code: code, message: "The Graph Studio local MCP endpoint is unavailable.")
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == kind.fileType,
              info.st_mode & 0o777 == requiredMode
        else {
            throw MCPBridgeError(code: "APP_BRIDGE_UNTRUSTED", message: "The Graph Studio local MCP endpoint has unsafe ownership or permissions.")
        }
    }

    private static func findApplication() -> URL? {
        // A bundled helper must launch the app that contains it. Launch Services
        // may otherwise resolve this bundle identifier to an older installed copy.
        if let executable = Bundle.main.executableURL {
            let macOSDirectory = executable.deletingLastPathComponent()
            let contentsDirectory = macOSDirectory.deletingLastPathComponent()
            let siblingApp = contentsDirectory.deletingLastPathComponent()
            if macOSDirectory.lastPathComponent == "MacOS",
               contentsDirectory.lastPathComponent == "Contents",
               siblingApp.pathExtension == "app",
               Bundle(url: siblingApp)?.bundleIdentifier == MCPBridgePaths.appBundleIdentifier {
                return siblingApp.standardizedFileURL
            }
        }
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MCPBridgePaths.appBundleIdentifier) {
            return registered
        }
        let candidates = [
            URL(fileURLWithPath: "/Applications/SQLiteGraphStudio.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/SQLiteGraphStudio.app", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/SQLiteGraphStudio.app", isDirectory: true),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }
    }

    private static func openApplication(_ url: URL, foreground: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = foreground ? ["-a", url.path] : ["-g", "-a", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MCPBridgeError(code: "APP_LAUNCH_FAILED", message: "The macOS open command did not start Graph Studio.")
        }
    }
}

private enum OwnedPathKind {
    case directory
    case regularFile
    case socket

    var fileType: mode_t {
        switch self {
        case .directory: S_IFDIR
        case .regularFile: S_IFREG
        case .socket: S_IFSOCK
        }
    }
}

private struct MCPBridgeError: Error {
    let code: String
    let message: String
}

private struct AuthenticatedSocket {
    let fileDescriptor: Int32
    let credential: String
    let clientID: String

    func handshake() throws -> [String: Any] {
        let response = try request(
            method: "bridge/hello",
            params: ["protocolVersion": 1, "clientId": clientID, "credential": credential],
            id: "hello-\(UUID().uuidString.lowercased())"
        )
        if let error = response["error"] as? [String: Any] {
            let data = error["data"] as? [String: Any] ?? [:]
            throw MCPBridgeError(
                code: data["code"] as? String ?? "APP_BRIDGE_AUTH_FAILED",
                message: error["message"] as? String ?? "The app rejected the local MCP handshake."
            )
        }
        guard let result = response["result"] as? [String: Any],
              (result["protocolVersion"] as? Int) == 1
        else {
            throw MCPBridgeError(code: "APP_PROTOCOL_ERROR", message: "The app returned an invalid bridge handshake.")
        }
        return result
    }

    func request(method: String, params: [String: Any], id: String) throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw MCPBridgeError(code: "APP_PROTOCOL_ERROR", message: "The local bridge request was not valid JSON.")
        }
        var line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard line.count <= 1_048_576 else {
            throw MCPBridgeError(code: "LIMIT_REACHED", message: "The local app request exceeds the 1 MiB bridge limit.")
        }
        line.append(0x0A)
        try writeAll(line)
        let responseData = try readLine()
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              response["jsonrpc"] as? String == "2.0",
              Self.idsEqual(response["id"], id)
        else {
            throw MCPBridgeError(code: "APP_PROTOCOL_ERROR", message: "The app returned an invalid bridge response.")
        }
        return response
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes { bytes in
                Darwin.send(fileDescriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            guard result > 0 else {
                throw MCPBridgeError(code: "APP_BRIDGE_UNAVAILABLE", message: "The local app socket closed during a request.")
            }
            offset += result
        }
    }

    private func readLine() throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while result.count <= MCPLineFramer.defaultMaximumMessageBytes {
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw MCPBridgeError(code: "APP_BRIDGE_UNAVAILABLE", message: "The local app socket closed before replying.")
            }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[..<newline])
                return result
            }
            result.append(contentsOf: buffer[..<count])
        }
        throw MCPBridgeError(code: "APP_PROTOCOL_ERROR", message: "The app response exceeded the 4 MiB limit.")
    }

    private static func idsEqual(_ lhs: Any?, _ rhs: String) -> Bool {
        lhs as? String == rhs
    }
}

private func makeToolResult(summary: String, structuredContent: [String: Any]) -> [String: Any] {
    [
        "content": [["type": "text", "text": summary]],
        "structuredContent": structuredContent,
        "isError": false,
    ]
}

private func errorResult(
    code: String,
    message: String,
    extra: [String: Any] = [:]
) -> [String: Any] {
    var error: [String: Any] = ["code": code, "message": message]
    for (key, value) in extra where key != "code" && key != "message" {
        error[key] = value
    }
    let structured: [String: Any] = ["error": error]
    return [
        "content": [["type": "text", "text": message]],
        "structuredContent": structured,
        "isError": true,
    ]
}
