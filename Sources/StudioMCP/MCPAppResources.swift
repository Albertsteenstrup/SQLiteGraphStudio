import Foundation

/// MCP Apps views served by the helper. A tool names its view with
/// `_meta.ui.resourceUri`; supporting hosts read the HTML through
/// `resources/read` and render it in a sandboxed frame inside the conversation.
public enum MCPAppResources {
    public static let extensionIdentifier = "io.modelcontextprotocol/ui"
    public static let mimeType = "text/html;profile=mcp-app"
    public static let schemaReviewURI = "ui://sqlite-graph-studio/schema-review.html"

    public static var resources: [[String: Any]] {
        [[
            "uri": schemaReviewURI,
            "name": "schema-review",
            "title": "Schema review",
            "description": "Interactive schema comparison or proposal view for studio_show_review_inline.",
            "mimeType": mimeType,
        ]]
    }

    /// The `resources/read` result for `uri`, or nil when the helper serves no such view.
    public static func read(_ uri: String) -> [String: Any]? {
        guard uri == schemaReviewURI, let html = schemaReviewHTML else { return nil }
        return [
            "contents": [[
                "uri": uri,
                "mimeType": mimeType,
                "text": html,
                // Self-contained: no network, fonts, or frames, so the host's default
                // sandbox policy applies unchanged.
                "_meta": ["ui": ["prefersBorder": true]],
            ]],
        ]
    }

    static let schemaReviewHTML: String? = Bundle.module
        .url(forResource: "SchemaReviewApp", withExtension: "html", subdirectory: "Resources")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}
