import Foundation

/// Presents the existing read-only row APIs through an MCP App without opening
/// native table/query panes. Paging remains scoped to the caller's exact context,
/// workspace and source; query pages always come from the captured result.
public enum DataInlineView {
    public static let toolName = "studio_show_data_inline"
    /// No view resource is attached to page requests: only the initial show
    /// action creates a card. The reader's controls update that existing card.
    public static let pageToolName = "studio_data_page"
    public static let format = "sqlite-graph-studio/data-view"

    static func result(_ call: MCPToolCall, transport: MCPBridgeTransport) -> [String: Any] {
        let args = call.arguments
        guard let contextID = call.contextID, !contextID.isEmpty else {
            return error("INVALID_ARGUMENT", "Include this task's exact context_id from studio_connect_context.")
        }
        let table = args["table_id"] as? String
        let query = args["result_id"] as? String
        guard (table != nil) != (query != nil), !(table ?? query ?? "").isEmpty else {
            return error("INVALID_ARGUMENT", "Provide exactly one table_id or captured result_id.")
        }
        let tableKeys = ["source_id", "source_revision", "table_id", "column_ids", "filters", "sort", "search_text"]
        if query != nil && tableKeys.contains(where: { args[$0] != nil }) {
            return error("INVALID_ARGUMENT", "Filters, sorting and source selection apply only to table pages. Run a new read-only query to change a captured result.")
        }
        let keys = ["workspace_id", "offset", "limit"] + (table != nil ? tableKeys : ["result_id"])
        var pageArguments = args.filter { keys.contains($0.key) }
        pageArguments["context_id"] = contextID
        pageArguments["offset"] = max(0, args["offset"] as? Int ?? 0)
        pageArguments["limit"] = min(100, max(1, args["limit"] as? Int ?? 50))
        let fetch = MCPToolCall(name: table != nil ? "studio_fetch_rows" : "studio_fetch_query_results",
                                arguments: pageArguments, contextID: contextID, clientID: call.clientID,
                                clientName: call.clientName, clientVersion: call.clientVersion,
                                workingDirectory: call.workingDirectory)
        var result = transport.call(fetch, contextID: contextID)
        guard result["isError"] as? Bool != true else { return result }
        guard var data = result["structuredContent"] as? [String: Any],
              data["columns"] is [Any], let rows = data["rows"] as? [[String: Any]] else {
            return error("INVALID_RESPONSE", "Graph Studio returned no data page. Update the app and its MCP helper together.")
        }
        // Pin every later page, even if the task subsequently selects another
        // workspace or refreshes its source. Never fall back to a new selection.
        for key in ["workspace_id", "source_id", "source_revision"] {
            if let value = data[key] as? String { pageArguments[key] = value }
        }
        let title = args["title"] as? String ?? table ?? "Query result"
        pageArguments["title"] = title
        data["format"] = format
        data["kind"] = table != nil ? "table" : "query"
        data["title"] = title
        data["page_size"] = pageArguments["limit"]
        result["structuredContent"] = data
        var meta = result["_meta"] as? [String: Any] ?? [:]
        meta["dataView"] = ["arguments": pageArguments]
        result["_meta"] = meta
        result["content"] = [["type": "text", "text": summary(data, rows: rows)]]
        if let bytes = try? JSONSerialization.data(withJSONObject: result), bytes.count > 1_048_576 {
            return error("LIMIT_REACHED", "The data view exceeded 1 MiB. Select fewer columns or a smaller page limit and retry.")
        }
        return result
    }

    /// Text-only hosts still receive a useful preview. Preserve positional
    /// columns (including duplicate names) and never parse decimal strings.
    private static func summary(_ data: [String: Any], rows: [[String: Any]]) -> String {
        let title = data["title"] as? String ?? "Data"
        let offset = data["offset"] as? Int ?? 0
        let scope = data["kind"] as? String == "query" ? "captured query rows" : "live table rows"
        var text = "\(markdown(title)): \(rows.count) \(scope) at offset \(offset)."
        if data["has_more"] as? Bool == true { text += " More pages are available." }
        if data["source_truncated"] as? Bool == true { text += " The query reached its row cap; this is a partial result." }
        guard let rawColumns = data["columns"] as? [Any], !rawColumns.isEmpty, !rows.isEmpty else { return text }
        let columns = rawColumns.prefix(12).map { column -> String in
            (column as? String) ?? (column as? [String: Any])?["name"] as? String ?? "Column"
        }
        text += "\n\n| " + columns.map(markdown).joined(separator: " | ") + " |\n| "
            + columns.map { _ in "---" }.joined(separator: " | ") + " |"
        for row in rows.prefix(10) {
            let values = row["values"] as? [[String: Any]] ?? []
            let cells = columns.indices.map { index -> String in
                guard index < values.count else { return "—" }
                let cell = values[index]
                if cell["type"] as? String == "null" { return "NULL" }
                if cell["type"] as? String == "blob" { return "Binary · \(cell["byte_count"] as? Int ?? 0) bytes" }
                let value = cell["value"] as? String ?? ""
                var display = String(value.prefix(160))
                if value.isEmpty { display = "\"\"" }
                else if value == "NULL" { display = "\"NULL\"" }
                if value.count > 160 || cell["truncated"] as? Bool == true { display += "… (partial)" }
                return markdown(display)
            }
            text += "\n| " + cells.joined(separator: " | ") + " |"
        }
        if rows.count > 10 || rawColumns.count > 12 { text += "\n\nText preview: first 10 rows and 12 columns of this page. The embedded view shows the full page." }
        return text
    }

    private static func markdown(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ↵ ")
        for character in ["\\", "|", "`", "*", "_", "[", "]"] {
            value = value.replacingOccurrences(of: character, with: "\\" + character)
        }
        return value
    }

    private static func error(_ code: String, _ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]],
         "structuredContent": ["error": ["code": code, "message": message]], "isError": true]
    }
}
