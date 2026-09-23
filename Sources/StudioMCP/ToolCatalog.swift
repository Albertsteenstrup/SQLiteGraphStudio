import Foundation

public struct MCPToolDefinition: @unchecked Sendable {
    public let name: String
    public let json: [String: Any]

    fileprivate init(json: [String: Any]) {
        name = json["name"] as? String ?? ""
        self.json = json
    }
}

public enum MCPToolCatalog {
    public static let tools: [MCPToolDefinition] = {
        guard let url = Bundle.module.url(
            forResource: "ToolCatalog",
            withExtension: "json",
            subdirectory: "Resources"
        ), let data = try? Data(contentsOf: url),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            preconditionFailure("The bundled SQLite Graph Studio MCP tool catalog is missing or invalid.")
        }
        return entries.map { original in
            var entry = original
            let name = entry["name"] as? String ?? ""
            if !["studio_status", "studio_launch", "studio_connect_context"].contains(name) {
                var schema = entry["inputSchema"] as? [String: Any] ?? [:]
                var properties = schema["properties"] as? [String: Any] ?? [:]
                properties["context_id"] = [
                    "type": "string",
                    "description": "Exact opaque context_id returned to this coding task by studio_connect_context. Include it on every app-bound call and never reuse another task's context; a client may serve several tasks.",
                ]
                schema["properties"] = properties
                var required = schema["required"] as? [String] ?? []
                if !required.contains("context_id") { required.append("context_id") }
                schema["required"] = required
                entry["inputSchema"] = schema
            }
            return MCPToolDefinition(json: entry)
        }
    }()

    private static let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    public static func tool(named name: String) -> MCPToolDefinition? {
        toolsByName[name]
    }

    public static var names: [String] {
        tools.map(\.name)
    }
}
