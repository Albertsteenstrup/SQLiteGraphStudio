import Foundation
import CoreFoundation

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
            guard let tool = MCPToolCatalog.tool(named: name) else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32602, "Unknown tool: \(name)", nil)
                )
            }

            guard let inputSchema = tool.json["inputSchema"] as? [String: Any] else {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32603, "The tool catalog has no valid input schema for \(name).", ["tool": name])
                )
            }
            if let issue = MCPToolArgumentSchemaValidator.validate(arguments, against: inputSchema) {
                return responseIfNeeded(
                    isNotification: isNotification,
                    id: requestID,
                    error: (-32602, "Invalid arguments for \(name) at \(issue.path): \(issue.message)", [
                        "code": "INVALID_ARGUMENT",
                        "tool": name,
                        "path": issue.path,
                        "keyword": issue.keyword,
                        "detail": issue.message,
                    ])
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

private struct MCPToolArgumentSchemaIssue {
    let path: String
    let keyword: String
    let message: String
}

/// Validates the JSON Schema subset used by the bundled MCP tool catalog.
/// Keeping this at the protocol boundary means malformed calls never reach the
/// app bridge, while source and workspace invariants remain coordinator policy.
private enum MCPToolArgumentSchemaValidator {
    private static let maximumDepth = 64

    static func validate(_ value: Any, against schema: [String: Any]) -> MCPToolArgumentSchemaIssue? {
        validate(value, against: schema, path: "", depth: 0)
    }

    private static func validate(
        _ value: Any,
        against schema: [String: Any],
        path: String,
        depth: Int
    ) -> MCPToolArgumentSchemaIssue? {
        guard depth < maximumDepth else {
            return issue(path, "depth", "The argument structure is nested too deeply.")
        }

        if let declaredType = schema["type"] {
            let allowedTypes = (declaredType as? [String]) ?? (declaredType as? String).map { [$0] }
            if let allowedTypes, !allowedTypes.contains(where: { matchesType(value, type: $0) }) {
                return issue(path, "type", "Expected \(allowedTypes.joined(separator: " or ")).")
            }
        }

        if let allowedValues = schema["enum"] as? [Any],
           !allowedValues.contains(where: { areJSONEqual(value, $0) }) {
            return issue(path, "enum", "The value is not one of the allowed choices.")
        }
        if let constant = schema["const"], !areJSONEqual(value, constant) {
            return issue(path, "const", "The value does not match the required constant.")
        }

        if let number = jsonNumber(value) {
            if let minimum = jsonNumber(schema["minimum"]), number.compare(minimum) == .orderedAscending {
                return issue(path, "minimum", "The number is below the allowed minimum.")
            }
            if let maximum = jsonNumber(schema["maximum"]), number.compare(maximum) == .orderedDescending {
                return issue(path, "maximum", "The number is above the allowed maximum.")
            }
            if let minimum = jsonNumber(schema["exclusiveMinimum"]), number.compare(minimum) != .orderedDescending {
                return issue(path, "exclusiveMinimum", "The number must be greater than the exclusive minimum.")
            }
            if let maximum = jsonNumber(schema["exclusiveMaximum"]), number.compare(maximum) != .orderedAscending {
                return issue(path, "exclusiveMaximum", "The number must be less than the exclusive maximum.")
            }
        }

        if let string = value as? String {
            let length = string.unicodeScalars.count
            if let minimum = schema["minLength"] as? Int, length < minimum {
                return issue(path, "minLength", "The string is shorter than the allowed minimum length.")
            }
            if let maximum = schema["maxLength"] as? Int, length > maximum {
                return issue(path, "maxLength", "The string is longer than the allowed maximum length.")
            }
            if let pattern = schema["pattern"] as? String {
                guard let expression = try? NSRegularExpression(pattern: pattern) else {
                    return issue(path, "pattern", "The catalog contains an invalid string pattern.")
                }
                let range = NSRange(string.startIndex..<string.endIndex, in: string)
                guard expression.firstMatch(in: string, range: range) != nil else {
                    return issue(path, "pattern", "The string does not match the required pattern.")
                }
            }
        }

        if let array = value as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum {
                return issue(path, "minItems", "The array has fewer items than the allowed minimum.")
            }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum {
                return issue(path, "maxItems", "The array has more items than the allowed maximum.")
            }
            if let itemSchema = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() {
                    if let failure = validate(item, against: itemSchema, path: childPath(path, String(index)), depth: depth + 1) {
                        return failure
                    }
                }
            }
        }

        if let object = value as? [String: Any] {
            if let required = schema["required"] as? [String] {
                for key in required.sorted() where object[key] == nil {
                    return issue(childPath(path, key), "required", "A required argument is missing.")
                }
            }

            if let properties = schema["properties"] as? [String: [String: Any]] {
                for key in properties.keys.sorted() {
                    guard let child = object[key], let childSchema = properties[key] else { continue }
                    if let failure = validate(child, against: childSchema, path: childPath(path, key), depth: depth + 1) {
                        return failure
                    }
                }

                let additionalSchema = schema["additionalProperties"]
                for key in object.keys.sorted() where properties[key] == nil {
                    if let allowed = additionalSchema as? Bool, !allowed {
                        return issue(childPath(path, key), "additionalProperties", "This argument is not supported.")
                    }
                    if let childSchema = additionalSchema as? [String: Any], let child = object[key] {
                        if let failure = validate(child, against: childSchema, path: childPath(path, key), depth: depth + 1) {
                            return failure
                        }
                    }
                }
            } else if let allowed = schema["additionalProperties"] as? Bool, !allowed,
                      let unexpected = object.keys.sorted().first {
                return issue(childPath(path, unexpected), "additionalProperties", "This argument is not supported.")
            }

            if let dependencies = schema["dependentRequired"] as? [String: [String]] {
                for trigger in dependencies.keys.sorted() where object[trigger] != nil {
                    for dependency in (dependencies[trigger] ?? []).sorted() where object[dependency] == nil {
                        return issue(childPath(path, dependency), "dependentRequired", "This argument is required when \(trigger) is supplied.")
                    }
                }
            }
        }

        if let alternatives = schema["anyOf"] as? [[String: Any]],
           !alternatives.contains(where: { validate(value, against: $0, path: path, depth: depth + 1) == nil }) {
            return issue(path, "anyOf", "The arguments do not match any supported input shape.")
        }
        if let alternatives = schema["oneOf"] as? [[String: Any]] {
            let matches = alternatives.reduce(into: 0) { count, alternative in
                if validate(value, against: alternative, path: path, depth: depth + 1) == nil { count += 1 }
            }
            if matches != 1 {
                return issue(path, "oneOf", "The arguments must match exactly one supported input shape.")
            }
        }
        if let schemas = schema["allOf"] as? [[String: Any]] {
            for childSchema in schemas {
                if let failure = validate(value, against: childSchema, path: path, depth: depth + 1) { return failure }
            }
        }
        if let condition = schema["if"] as? [String: Any] {
            let conditionMatches = validate(value, against: condition, path: path, depth: depth + 1) == nil
            let consequence = conditionMatches ? schema["then"] : schema["else"]
            if let consequence = consequence as? [String: Any],
               let failure = validate(value, against: consequence, path: path, depth: depth + 1) {
                return failure
            }
        }
        if let excluded = schema["not"] as? [String: Any],
           validate(value, against: excluded, path: path, depth: depth + 1) == nil {
            return issue(path, "not", "The arguments match a disallowed input shape.")
        }

        return nil
    }

    private static func matchesType(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return jsonBoolean(value) != nil
        case "number": return jsonNumber(value) != nil
        case "integer":
            guard let number = jsonNumber(value) else { return false }
            let value = number.doubleValue
            return value.isFinite && value.rounded(.towardZero) == value
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func areJSONEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = jsonNumber(lhs), let right = jsonNumber(rhs) { return left.compare(right) == .orderedSame }
        if let left = jsonBoolean(lhs), let right = jsonBoolean(rhs) { return left == right }
        if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy { areJSONEqual($0.0, $0.1) }
        }
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            guard left.count == right.count else { return false }
            return left.allSatisfy { key, value in right[key].map { areJSONEqual(value, $0) } ?? false }
        }
        return false
    }

    private static func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number
    }

    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func childPath(_ path: String, _ component: String) -> String {
        path + "/" + component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func issue(_ path: String, _ keyword: String, _ message: String) -> MCPToolArgumentSchemaIssue {
        MCPToolArgumentSchemaIssue(path: path.isEmpty ? "/" : path, keyword: keyword, message: message)
    }
}
