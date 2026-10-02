import Foundation

/// Embeds a dedicated native graph surface and the rows explicitly needed by
/// each explanation step. The viewer owns Back/Next navigation;
/// its decoded graph and installed data acknowledge presentation visibility.
public enum WorkspaceInlineView {
    public static let toolName = "studio_show_workspace_inline"
    public static let frameToolName = "studio_workspace_frame"
    public static let format = "sqlite-graph-studio/workspace-view"

    static func result(_ call: MCPToolCall, transport: MCPBridgeTransport) -> [String: Any] {
        guard let contextID = call.contextID, !contextID.isEmpty else {
            return error("CONTEXT_REQUIRED", "Include this chat's exact context_id.")
        }
        let keys = ["workspace_id", "source_id", "source_revision", "width", "after_frame_revision",
                    "viewer_id", "inline_view_state", "rendered_point_id", "maximum_frame_age_ms", "defer_until_ready",
                    "render_surface", "height", "graph_actions"]
        var args = call.arguments.filter { keys.contains($0.key) }
        if call.name == toolName {
            args["viewer_id"] = UUID().uuidString
            args["inline_view_state"] = "start"
            args["render_surface"] = "graph"
        }
        args["context_id"] = contextID
        let fetch = MCPToolCall(name: frameToolName, arguments: args, contextID: contextID,
                                clientID: call.clientID, clientName: call.clientName,
                                clientVersion: call.clientVersion, workingDirectory: call.workingDirectory)
        var result = transport.call(fetch, contextID: contextID)
        if result["isError"] as? Bool == true { return result }
        guard var data = result["structuredContent"] as? [String: Any],
              data["format"] as? String == format,
              let workspace = data["workspace_id"] as? String,
              let source = data["source_id"] as? String,
              let revision = data["source_revision"] as? String else {
            return error("INVALID_RESPONSE", "Graph Studio returned no workspace frame.")
        }
        for key in ["workspace_id", "source_id", "source_revision"] {
            if let requested = args[key] as? String, requested != data[key] as? String {
                return error("STALE_SOURCE", "The frame does not match this chat's workspace and source.")
            }
        }
        let image = data.removeValue(forKey: "image") as? String
        let mime = data.removeValue(forKey: "mimeType") as? String ?? "image/jpeg"
        let title = call.arguments["title"] as? String ?? data["title"] as? String ?? "SQLite Graph Studio"
        data["title"] = title
        // Some hosts omit result _meta in the initial UI notification. These
        // opaque IDs are already known to the caller; authorization still uses
        // the MCP client and context ownership, never these fields alone.
        data["viewer"] = ["context_id": contextID, "viewer_id": args["viewer_id"] ?? "legacy:\(contextID)",
                          "width": args["width"] as? Int ?? 960, "render_surface": args["render_surface"] ?? "workspace"]
        result["structuredContent"] = data
        var content: [[String: Any]] = [["type": "text", "text": "SQLite Graph Studio · \(title). Live native graph; data appears when an explanation point requests it."]]
        if let image { content.append(["type": "image", "mimeType": mime, "data": image]) }
        result["content"] = content
        if call.name == toolName {
            guard image != nil else { return error("VIEW_NOT_RENDERED", "No initial workspace frame is available yet.") }
            var route: [String: Any] = ["context_id": contextID, "workspace_id": workspace,
                                        "source_id": source, "source_revision": revision,
                                        "width": call.arguments["width"] as? Int ?? 960]
            route["title"] = title
            route["viewer_id"] = args["viewer_id"]
            route["render_surface"] = "graph"
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta["workspaceView"] = ["arguments": route]
            result["_meta"] = meta
        }
        return result
    }

    private static func error(_ code: String, _ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]],
         "structuredContent": ["error": ["code": code, "message": message]]]
    }
}
