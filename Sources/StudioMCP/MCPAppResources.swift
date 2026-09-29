import Foundation
import CryptoKit

/// MCP Apps views served by the helper. A tool names its view with
/// `_meta.ui.resourceUri`; supporting hosts read the HTML through
/// `resources/read` and render it in a sandboxed frame inside the conversation.
public enum MCPAppResources {
    public static let extensionIdentifier = "io.modelcontextprotocol/ui"
    public static let mimeType = "text/html;profile=mcp-app"
    private static let legacySchemaReviewURI = "ui://sqlite-graph-studio/schema-review.html"
    /// Hosts cache a view by URI. A new build must not reuse an older viewer's HTML.
    public static let schemaReviewURI = reviewURI(for: schemaReviewHTML ?? "")

    static func reviewURI(for html: String) -> String {
        let revision = SHA256.hash(data: Data(html.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "ui://sqlite-graph-studio/schema-review-\(revision).html"
    }

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
        guard uri == schemaReviewURI || uri == legacySchemaReviewURI,
              let html = schemaReviewHTML else { return nil }
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
