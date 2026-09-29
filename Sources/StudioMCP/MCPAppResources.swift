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
        guard isSchemaReviewURI(uri),
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

    private static func isSchemaReviewURI(_ uri: String) -> Bool {
        if uri == legacySchemaReviewURI { return true }
        // Saved cards and host discovery caches retain older versioned URIs after
        // the helper upgrades. They must still load the installed viewer. Keep the
        // requested URI in the response so the host can match its pending read.
        let prefix = "ui://sqlite-graph-studio/schema-review-"
        let suffix = ".html"
        guard uri.hasPrefix(prefix), uri.hasSuffix(suffix) else { return false }
        let revision = uri.dropFirst(prefix.count).dropLast(suffix.count)
        return revision.count == 24 && revision.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static let schemaReviewHTML: String? = Bundle.module
        .url(forResource: "SchemaReviewApp", withExtension: "html", subdirectory: "Resources")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}
