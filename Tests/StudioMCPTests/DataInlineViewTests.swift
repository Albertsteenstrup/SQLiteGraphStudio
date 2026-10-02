import Foundation
import XCTest
@testable import StudioMCP

final class DataInlineViewTests: XCTestCase {
    func testTableViewReadsWithoutNativeActionsAndPinsSubsequentPages() throws {
        let transport = DataPageTransport(page: [
            "workspace_id": "workspace-one", "source_id": "sqlite:/one", "source_revision": "revision-one",
            "table_id": "payments", "offset": 5, "limit": 2, "has_more": true,
            "columns": ["amount", "memo", "attachment"],
            "rows": [["index": 5, "values": [
                ["type": "numeric", "value": "9007199254740993.00"],
                ["type": "text", "value": "<script>alert('row')</script>|[link](url)"],
                ["type": "blob", "value": NSNull(), "byte_count": 128],
            ]]],
        ])
        let server = try server(transport)
        let response = try invoke(server, arguments: [
            "context_id": "task-one", "table_id": "payments", "column_ids": ["amount", "memo", "attachment"],
            "offset": 5, "limit": 2, "filters": [["column_name": "amount", "comparison": "greaterThan", "value": "1.25"]],
            "sort": [["column_name": "amount", "direction": "descending"]], "title": "Large payments",
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let data = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(data["format"] as? String, "sqlite-graph-studio/data-view")
        XCTAssertEqual(data["kind"] as? String, "table")
        XCTAssertEqual(data["title"] as? String, "Large payments")
        let rows = try XCTUnwrap(data["rows"] as? [[String: Any]])
        let cells = try XCTUnwrap(rows.first?["values"] as? [[String: Any]])
        XCTAssertEqual(cells[0]["value"] as? String, "9007199254740993.00")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("9007199254740993.00"))
        XCTAssertTrue(text.contains("&lt;script&gt;"))
        XCTAssertTrue(text.contains("Binary · 128 bytes"))
        XCTAssertFalse(text.contains("<script>"))
        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        let route = try XCTUnwrap((meta["dataView"] as? [String: Any])?["arguments"] as? [String: Any])
        XCTAssertEqual(route["context_id"] as? String, "task-one")
        XCTAssertEqual(route["workspace_id"] as? String, "workspace-one")
        XCTAssertEqual(route["source_id"] as? String, "sqlite:/one")
        XCTAssertEqual(route["source_revision"] as? String, "revision-one")
        var next = route
        next["offset"] = 6
        _ = try invoke(server, arguments: next, name: "studio_data_page")
        XCTAssertEqual(transport.calls.map(\.name), ["studio_fetch_rows", "studio_fetch_rows"])
        XCTAssertTrue(transport.calls.allSatisfy { $0.contextID == "task-one" && $0.clientID == "data-client" })
        XCTAssertEqual(transport.calls.last?.arguments["source_revision"] as? String, "revision-one")
        XCTAssertEqual(transport.calls.last?.arguments["offset"] as? Int, 6)
        XCTAssertEqual(transport.calls.last?.arguments["column_ids"] as? [String], ["amount", "memo", "attachment"])
        XCTAssertEqual((transport.calls.last?.arguments["filters"] as? [[String: String]])?.first?["value"], "1.25")
        XCTAssertNil(transport.calls.last?.arguments["title"])
    }

    func testQueryViewPreservesPositionalColumnsNullAndPartialResultWithoutRunningSQL() throws {
        let transport = DataPageTransport(page: [
            "workspace_id": "workspace-query", "result_id": "result:one", "row_count": 3,
            "offset": 0, "returned_rows": 1, "has_more": true, "source_truncated": true,
            "executed_sql": "SELECT NULL AS value, 'NULL' AS value, '' AS empty",
            "columns": [["id": 0, "name": "value", "type": "TEXT"],
                        ["id": 1, "name": "value", "type": "TEXT"], ["id": 2, "name": "empty", "type": "TEXT"]],
            "rows": [["id": 0, "values": [["type": "null", "value": NSNull()],
                                            ["type": "text", "value": "NULL"], ["type": "text", "value": ""]]]],
        ])
        let result = try XCTUnwrap(try invoke(server(transport), arguments: ["context_id": "task-query", "result_id": "result:one"])["result"] as? [String: Any])
        let data = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let columns = try XCTUnwrap(data["columns"] as? [[String: Any]])
        XCTAssertEqual(columns.map { $0["name"] as? String }, ["value", "value", "empty"])
        XCTAssertEqual(columns.map { $0["id"] as? Int }, [0, 1, 2])
        XCTAssertEqual(data["source_truncated"] as? Bool, true)
        XCTAssertEqual(data["kind"] as? String, "query")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("partial result"))
        XCTAssertTrue(text.contains("| NULL | \"NULL\" | \"\" |"))
        XCTAssertEqual(transport.calls.map(\.name), ["studio_fetch_query_results"])
        XCTAssertEqual(transport.calls.first?.arguments["limit"] as? Int, 50)
    }

    func testSchemaRejectsAmbiguousSelectionsMissingContextsAndQueryTransformations() throws {
        let transport = DataPageTransport(page: [:])
        let server = try server(transport)
        let invalid: [[String: Any]] = [
            ["context_id": "task"],
            ["table_id": "items"],
            ["context_id": "task", "table_id": ""],
            ["context_id": "task", "table_id": "items", "result_id": "result:one"],
            ["context_id": "task", "result_id": "result:one", "filters": []],
            ["context_id": "task", "result_id": "result:one", "source_id": "other"],
            ["context_id": "task", "result_id": "result:one", "sql": "SELECT 1"],
            ["context_id": "task", "table_id": "items", "limit": 101],
            ["context_id": "task", "table_id": "items", "offset": -1],
        ]
        for arguments in invalid {
            let response = try invoke(server, arguments: arguments)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(arguments)")
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testBridgeFailureRemainsAnErrorInsteadOfAnEmptyEmbeddedGrid() throws {
        let transport = DataPageTransport(page: [:])
        transport.failure = ["content": [["type": "text", "text": "This source has schema only."]],
                             "structuredContent": ["error": ["code": "SCHEMA_ONLY_SOURCE", "message": "This source has schema only."]],
                             "isError": true]
        let result = try XCTUnwrap(try invoke(server(transport), arguments: ["context_id": "task", "table_id": "items"])["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let data = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual((data["error"] as? [String: Any])?["code"] as? String, "SCHEMA_ONLY_SOURCE")
        XCTAssertNil(data["format"])
        XCTAssertNil(result["_meta"])
    }

    func testDataToolAdvertisesItsVersionedViewAndSavedViewsSurviveAnUpgrade() throws {
        let tool = try XCTUnwrap(MCPToolCatalog.tool(named: "studio_show_data_inline")?.json)
        let meta = try XCTUnwrap(tool["_meta"] as? [String: Any])
        XCTAssertEqual((meta["ui"] as? [String: Any])?["resourceUri"] as? String, MCPAppResources.dataURI)
        XCTAssertEqual(meta["ui/resourceUri"] as? String, MCPAppResources.dataURI)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String])?.contains("context_id") == true)
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        let pager = try XCTUnwrap(MCPToolCatalog.tool(named: "studio_data_page")?.json)
        let pageMeta = try XCTUnwrap(pager["_meta"] as? [String: Any])
        let pageUI = try XCTUnwrap(pageMeta["ui"] as? [String: Any])
        XCTAssertEqual(pageUI["visibility"] as? [String], ["app"])
        XCTAssertNil(pageUI["resourceUri"], "Page requests update the existing card instead of creating another view")
        XCTAssertNil(pageMeta["ui/resourceUri"])
        let html = try XCTUnwrap(MCPAppResources.dataHTML)
        XCTAssertNotEqual(MCPAppResources.dataURI(for: html), MCPAppResources.dataURI(for: html + "changed"))
        for uri in ["ui://sqlite-graph-studio/data.html", MCPAppResources.dataURI(for: "previous build"), MCPAppResources.dataURI] {
            let read = try XCTUnwrap(MCPAppResources.read(uri))
            let resource = try XCTUnwrap((read["contents"] as? [[String: Any]])?.first)
            XCTAssertEqual(resource["uri"] as? String, uri)
            XCTAssertEqual(resource["text"] as? String, html)
            XCTAssertEqual(resource["mimeType"] as? String, "text/html;profile=mcp-app")
        }
        XCTAssertNil(MCPAppResources.read("ui://sqlite-graph-studio/data-invalid.html"))
        XCTAssertNil(MCPAppResources.read("ui://another-server/data.html"))
    }

    private func server(_ transport: DataPageTransport) throws -> MCPServer {
        let server = MCPServer(dispatcher: LocalMCPToolDispatcher(transport: transport), clientID: "data-client")
        _ = try invokeMessage(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                      "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "data-test", "version": "1"]]])
        _ = server.handleMessage(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        return server
    }

    private func invoke(_ server: MCPServer, arguments: [String: Any], name: String = "studio_show_data_inline") throws -> [String: Any] {
        try invokeMessage(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": ["name": name, "arguments": arguments]])
    }

    private func invokeMessage(_ server: MCPServer, _ message: [String: Any]) throws -> [String: Any] {
        let reply = try XCTUnwrap(server.handleMessage(JSONSerialization.data(withJSONObject: message)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }
}

private final class DataPageTransport: MCPBridgeTransport {
    let page: [String: Any]
    var calls: [MCPToolCall] = []
    var failure: [String: Any]?

    init(page: [String: Any]) { self.page = page }
    func status(clientID: String) -> [String: Any] { XCTFail("Showing data must not launch or probe the app."); return [:] }
    func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any] { XCTFail("Showing data must not launch the app."); return [:] }
    func call(_ call: MCPToolCall, contextID: String?) -> [String: Any] {
        calls.append(call)
        return failure ?? ["content": [["type": "text", "text": "Page fetched"]], "structuredContent": page, "isError": false]
    }
}
