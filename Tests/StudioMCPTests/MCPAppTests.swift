import Foundation
import XCTest
@testable import StudioMCP

final class MCPAppTests: XCTestCase {
    func testBothProtocolsAdvertiseResourcesAndTheUIExtension() throws {
        let server = MCPServer(dispatcher: LocalMCPToolDispatcher(transport: UnusedTransport()))
        let initialize = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": ["extensions": [MCPAppResources.extensionIdentifier: ["mimeTypes": [MCPAppResources.mimeType]]]],
                "clientInfo": ["name": "test", "version": "1"],
            ],
        ])))
        let legacy = (initialize["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil(legacy?["resources"] as? [String: Any])
        XCTAssertNotNil((legacy?["extensions"] as? [String: Any])?[MCPAppResources.extensionIdentifier])

        let discovery = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 2, "method": "server/discover",
            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": MCPServer.modernProtocolVersion]],
        ])))
        let modern = (discovery["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil(modern?["resources"] as? [String: Any])
        XCTAssertNotNil((modern?["extensions"] as? [String: Any])?[MCPAppResources.extensionIdentifier])
    }

    func testServesSelfContainedViewsThatNeverTouchTheNetwork() throws {
        let server = try initializedServer()
        let list = try object(server.handleMessage(json(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])))
        let resources = (list["result"] as? [String: Any])?["resources"] as? [[String: Any]]
        XCTAssertEqual(resources?.map { $0["uri"] as? String }, [MCPAppResources.dataURI, MCPAppResources.workspaceURI])
        XCTAssertEqual(resources?.first?["mimeType"] as? String, "text/html;profile=mcp-app")

        let read = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": MCPAppResources.workspaceURI],
        ])))
        let content = try XCTUnwrap(((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["mimeType"] as? String, "text/html;profile=mcp-app")
        XCTAssertEqual(((content["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["prefersBorder"] as? Bool, true)
        let html = try XCTUnwrap(content["text"] as? String)
        XCTAssertNotNil(MCPAppResources.read("ui://sqlite-graph-studio/workspace.html"),
                        "Previously saved tool metadata can still load the current viewer")
        for handshake in ["ui/initialize", "ui/notifications/initialized", "ui/notifications/tool-result", "ui/notifications/size-changed"] {
            XCTAssertTrue(html.contains(handshake), handshake)
        }
        // The host's default sandbox allows no network, and view text must never become markup.
        for view in [try XCTUnwrap(MCPAppResources.dataHTML), try XCTUnwrap(MCPAppResources.workspaceHTML)] {
            for forbidden in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "fetch(", "XMLHttpRequest", "WebSocket", "<script src", "<link", "@import", "eval("] {
                XCTAssertFalse(view.contains(forbidden), forbidden)
            }
        }

        let missing = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": ["uri": "ui://sqlite-graph-studio/schema-review.html"],
        ])))
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32002)
    }

    func testSavedViewerResourceSurvivesHelperUpgrade() throws {
        let server = try initializedServer()
        let savedURIs = [
            "ui://sqlite-graph-studio/workspace.html",
            "ui://sqlite-graph-studio/workspace-0f35d5df75586fa11507f6fb.html",
        ]
        for uri in savedURIs {
            let read = try object(server.handleMessage(json([
                "jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": uri],
            ])))
            let content = try XCTUnwrap(((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first,
                                       "Previously advertised resource must still resolve: \(uri)")
            XCTAssertEqual(content["uri"] as? String, uri)
            XCTAssertEqual(content["text"] as? String, MCPAppResources.workspaceHTML)
            XCTAssertEqual(content["mimeType"] as? String, MCPAppResources.mimeType)
        }
        for uri in [
            "ui://another-server/workspace-0f35d5df75586fa11507f6fb.html",
            "ui://sqlite-graph-studio/other-0f35d5df75586fa11507f6fb.html",
            "ui://sqlite-graph-studio/workspace-invalid.html",
            "ui://sqlite-graph-studio/workspace-0f35d5df75586fa11507f6fb.html/extra",
        ] {
            XCTAssertNil(MCPAppResources.read(uri))
        }
    }

    private func initializedServer(transport: UnusedTransport = UnusedTransport(), workingDirectory: String = "/tmp") throws -> MCPServer {
        let server = MCPServer(dispatcher: LocalMCPToolDispatcher(transport: transport), workingDirectory: workingDirectory)
        _ = try server.handleMessage(json([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "test", "version": "1"]],
        ]))
        _ = try server.handleMessage(json(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        return server
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func object(_ value: Data?) -> [String: Any] {
        guard let value, let result = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else {
            XCTFail("Expected a JSON-RPC response")
            return [:]
        }
        return result
    }
}

private final class UnusedTransport: MCPBridgeTransport {
    private(set) var calls = 0

    func status(clientID: String) -> [String: Any] { calls += 1; return [:] }
    func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any] { calls += 1; return [:] }
    func call(_ call: MCPToolCall, contextID: String?) -> [String: Any] { calls += 1; return [:] }
}
