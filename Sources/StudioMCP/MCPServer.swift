import Foundation

public final class MCPServer {
    public static let serverVersion = "0.1.0"
    public static let modernProtocolVersion = "2026-07-28"
    public static let legacyProtocolVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
        "2024-10-07",
    ]

    private let dispatcher: MCPToolDispatcher
    private let clientID: String
    private let workingDirectory: String
    private var clientName: String?
    private var clientVersion: String?
    private var legacyProtocolVersion: String?
    private var initialized = false

    public init(
        dispatcher: MCPToolDispatcher,
        clientID: String = UUID().uuidString.lowercased(),
        workingDirectory: String = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"]
            ?? ProcessInfo.processInfo.environment["PWD"]
            ?? FileManager.default.currentDirectoryPath
    ) {
        self.dispatcher = dispatcher
        self.clientID = clientID
        self.workingDirectory = workingDirectory
    }

    /// Releases app-side state owned by this stdio client when its input stream ends.
    /// This is a private bridge lifecycle signal, not an MCP tool.
    public func clientDisconnected() {
        dispatcher.clientDisconnected(clientID: clientID)
    }

    /// Handles one complete JSON-RPC object and returns a complete JSON-RPC
    /// response. Notifications correctly return nil.
    public func handleMessage(_ data: Data) -> Data? {
        let request: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return encode(Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid Request"))
            }
            request = parsed
        } catch {
            return encode(Self.errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }

        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String
        else {
            return encode(Self.errorResponse(
                id: request["id"] ?? NSNull(),
                code: -32600,
                message: "Invalid Request"
            ))
        }

        let requestID = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        let modernVersion = Self.requestProtocolVersion(params: params)
        let isNotification = requestID == nil
        if modernVersion != nil,
           let clientInfo = (params["_meta"] as? [String: Any])?["io.modelcontextprotocol/clientInfo"] as? [String: Any] {
            clientName = clientInfo["name"] as? String
            clientVersion = clientInfo["version"] as? String
        }

        if method == "server/discover" {
            guard let requestVersion = modernVersion else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32602, "server/discover requires protocol version metadata", nil)
                )
            }
            guard requestVersion == Self.modernProtocolVersion else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32022, "Unsupported protocol version", [
                        "supported": Self.supportedProtocolVersions,
                        "requested": requestVersion,
                    ])
                )
            }
            return responseIfNeeded(isNotification: isNotification, id: requestID, result: Self.discoveryResult)
        }

        if method == "initialize" {
            return initialize(params: params, id: requestID, isNotification: isNotification)
        }

        if method == "notifications/initialized" {
            initialized = legacyProtocolVersion != nil
            return nil
        }

        if method == "notifications/cancelled" || method == "$/cancelRequest" {
            return nil
        }

        if let modernVersion, modernVersion != Self.modernProtocolVersion {
            return responseIfNeeded(
                isNotification: isNotification,
                id: requestID,
                error: (-32022, "Unsupported protocol version", [
                    "supported": Self.supportedProtocolVersions,
                    "requested": modernVersion,
                ])
            )
        }

        if method == "ping" {
            guard protocolIsReady(modernVersion: modernVersion) else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32002, "MCP session is not initialized or protocol metadata is missing", nil)
                )
            }
            return responseIfNeeded(isNotification: isNotification, id: requestID, result: [:])
        }

        guard protocolIsReady(modernVersion: modernVersion) else {
            return responseIfNeeded(
                isNotification: isNotification,
                id: requestID,
                error: (-32002, "MCP session is not initialized or protocol metadata is missing", nil)
            )
        }

        switch method {
        case "tools/list":
            let result: [String: Any] = ["tools": MCPToolCatalog.tools.map(\.json)]
            return responseIfNeeded(isNotification: isNotification, id: requestID, result: result)

        case "tools/call":
            guard let name = params["name"] as? String else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32602, "tools/call requires a tool name", nil)
                )
            }
            let arguments: [String: Any]
            if let parsedArguments = params["arguments"] as? [String: Any] {
                arguments = parsedArguments
            } else if params["arguments"] == nil {
                arguments = [:]
            } else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32602, "tools/call arguments must be an object", nil)
                )
            }
            guard MCPToolCatalog.tool(named: name) != nil else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32602, "Unknown tool: \(name)", nil)
                )
            }

            let contextID = arguments["context_id"] as? String
            let call = MCPToolCall(
                name: name,
                arguments: arguments,
                contextID: contextID,
                clientID: clientID,
                clientName: clientName,
                clientVersion: clientVersion,
                workingDirectory: workingDirectory
            )
            let result = dispatcher.dispatch(call)
            return responseIfNeeded(isNotification: isNotification, id: requestID, result: result)

        default:
            return responseIfNeeded(
                isNotification: isNotification,
                id: requestID,
                error: (-32601, "Method not found", nil)
            )
        }
    }

    public static var supportedProtocolVersions: [String] {
        [modernProtocolVersion] + legacyProtocolVersions
    }

    private static var discoveryResult: [String: Any] {
        [
            "resultType": "complete",
            "supportedVersions": supportedProtocolVersions,
            "capabilities": ["tools": ["listChanged": false]],
            "_meta": [
                "io.modelcontextprotocol/serverInfo": [
                    "name": "SQLite Graph Studio",
                    "version": serverVersion,
                ],
            ],
            "instructions": instructions,
            "ttlMs": 0,
            "cacheScope": "public",
        ]
    }

    private static var instructions: String {
        "Use studio_status before offering or opening a visualization; it never launches the app. Call studio_launch only for an explicit visualization request. Connect each coding task with studio_connect_context, then include its exact context_id on every app-bound call so parallel tasks stay isolated. Return source choices when the context is ambiguous. Results are bounded and MCP database access is read-only."
    }

    private func initialize(params: [String: Any], id: Any?, isNotification: Bool) -> Data? {
        guard let requestedVersion = params["protocolVersion"] as? String else {
            return responseIfNeeded(
                isNotification: isNotification,
                id: id,
                error: (-32602, "initialize requires protocolVersion", nil)
            )
        }
        guard Self.legacyProtocolVersions.contains(requestedVersion) else {
            return responseIfNeeded(
                isNotification: isNotification,
                id: id,
                error: (-32602, "Unsupported protocol version; supported versions: \(Self.legacyProtocolVersions.joined(separator: ", "))", [
                    "supported": Self.legacyProtocolVersions,
                    "requested": requestedVersion,
                ])
            )
        }

        legacyProtocolVersion = requestedVersion
        initialized = false
        let info = params["clientInfo"] as? [String: Any]
        clientName = info?["name"] as? String
        clientVersion = info?["version"] as? String
        let result: [String: Any] = [
            "protocolVersion": requestedVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "SQLite Graph Studio", "version": Self.serverVersion],
            "instructions": Self.instructions,
        ]
        return responseIfNeeded(isNotification: isNotification, id: id, result: result)
    }

    private func protocolIsReady(modernVersion: String?) -> Bool {
        if modernVersion != nil {
            return modernVersion == Self.modernProtocolVersion
        }
        return legacyProtocolVersion != nil && initialized
    }

    private static func requestProtocolVersion(params: [String: Any]) -> String? {
        guard let meta = params["_meta"] as? [String: Any] else { return nil }
        return meta["io.modelcontextprotocol/protocolVersion"] as? String
    }

    private func responseIfNeeded(
        isNotification: Bool,
        id: Any?,
        result: Any
    ) -> Data? {
        guard !isNotification, let id else { return nil }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func responseIfNeeded(
        isNotification: Bool,
        id: Any?,
        error: (Int, String, [String: Any]?)
    ) -> Data? {
        guard !isNotification, let id else { return nil }
        var payload: [String: Any] = ["code": error.0, "message": error.1]
        if let data = error.2 {
            payload["data"] = data
        }
        return encode(["jsonrpc": "2.0", "id": id, "error": payload])
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ value: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return data
    }
}
