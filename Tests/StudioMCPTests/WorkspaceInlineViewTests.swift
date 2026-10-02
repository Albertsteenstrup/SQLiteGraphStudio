import Foundation
import XCTest
@testable import StudioMCP

final class WorkspaceInlineViewTests: XCTestCase {
    func testNativeFrameIsForwardedWithPinnedWorkspaceAndNoNativeMutation() throws {
        let transport = FrameTransport()
        let call = MCPToolCall(name: WorkspaceInlineView.toolName,
                               arguments: ["context_id": "task", "title": "Posts", "width": 700],
                               contextID: "task", clientID: "client", clientName: "test", clientVersion: "1", workingDirectory: "/tmp")
        let result = LocalMCPToolDispatcher(transport: transport).dispatch(call)
        let data = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(data["format"] as? String, "sqlite-graph-studio/workspace-view")
        XCTAssertNil(data["image"], "Images must be MCP image content, not model JSON")
        let publicViewer = try XCTUnwrap(data["viewer"] as? [String: Any])
        XCTAssertEqual(publicViewer["context_id"] as? String, "task", "The UI must retain its connection when a host omits private metadata")
        let image = try XCTUnwrap((result["content"] as? [[String: Any]])?.first { $0["type"] as? String == "image" })
        XCTAssertEqual(image["data"] as? String, "native-frame")
        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        let route = try XCTUnwrap((meta["workspaceView"] as? [String: Any])?["arguments"] as? [String: Any])
        XCTAssertEqual(route["context_id"] as? String, "task")
        XCTAssertEqual(route["workspace_id"] as? String, "workspace")
        XCTAssertEqual(route["source_revision"] as? String, "revision")
        let viewer = try XCTUnwrap(route["viewer_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: viewer))
        XCTAssertEqual(publicViewer["viewer_id"] as? String, viewer)
        XCTAssertNil(publicViewer["resume_token"])
        XCTAssertEqual(transport.calls.first?.arguments["inline_view_state"] as? String, "start")
        XCTAssertEqual(transport.calls.first?.arguments["render_surface"] as? String, "graph")
        XCTAssertEqual(route["render_surface"] as? String, "graph")
        let refresh = MCPToolCall(name: WorkspaceInlineView.frameToolName, arguments: route,
                                  contextID: "task", clientID: "client", clientName: nil, clientVersion: nil, workingDirectory: "/tmp")
        _ = LocalMCPToolDispatcher(transport: transport).dispatch(refresh)
        XCTAssertEqual(transport.calls.map(\.name), ["studio_workspace_frame", "studio_workspace_frame"])
        XCTAssertEqual(transport.calls.last?.arguments["source_id"] as? String, "sqlite:/sample")
        XCTAssertEqual(transport.calls.last?.arguments["viewer_id"] as? String, viewer)
        XCTAssertTrue(transport.calls.allSatisfy { $0.clientID == "client" && $0.contextID == "task" })
        XCTAssertNil(transport.calls.first?.arguments["title"])
    }

    func testWrongSourceOrUnavailableWorkspaceNeverBecomesAFrame() {
        let transport = FrameTransport()
        let call = MCPToolCall(name: WorkspaceInlineView.toolName,
                               arguments: ["source_id": "sqlite:/different"], contextID: "task",
                               clientID: "client", clientName: nil, clientVersion: nil, workingDirectory: "/tmp")
        let wrong = LocalMCPToolDispatcher(transport: transport).dispatch(call)
        XCTAssertEqual(wrong["isError"] as? Bool, true)
        XCTAssertFalse((wrong["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image" })
        transport.unavailable = true
        let unavailable = LocalMCPToolDispatcher(transport: transport).dispatch(call)
        XCTAssertEqual(((unavailable["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "WORKSPACE_NOT_ACTIVE")
        XCTAssertNil(unavailable["_meta"])
    }

    func testOnlyTheInitialShowCreatesAnEmbeddedViewAndAllReadsRequireContext() throws {
        let show = try XCTUnwrap(MCPToolCatalog.tool(named: WorkspaceInlineView.toolName)?.json)
        let frame = try XCTUnwrap(MCPToolCatalog.tool(named: WorkspaceInlineView.frameToolName)?.json)
        XCTAssertEqual(((show["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["resourceUri"] as? String, MCPAppResources.workspaceURI)
        let ui = try XCTUnwrap((frame["_meta"] as? [String: Any])?["ui"] as? [String: Any])
        XCTAssertEqual(ui["visibility"] as? [String], ["app"])
        XCTAssertNil(ui["resourceUri"])
        for tool in [show, frame] {
            XCTAssertTrue(((tool["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []).contains("context_id"))
        }
    }
}

private final class FrameTransport: MCPBridgeTransport {
    var calls: [MCPToolCall] = []
    var unavailable = false
    func status(clientID: String) -> [String: Any] { [:] }
    func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any] { [:] }
    func call(_ call: MCPToolCall, contextID: String?) -> [String: Any] {
        calls.append(call)
        if unavailable {
            return ["isError": true, "content": [], "structuredContent": ["error": ["code": "WORKSPACE_NOT_ACTIVE", "message": "Another workspace is selected."]]]
        }
        return ["isError": false, "content": [], "structuredContent": [
            "format": "sqlite-graph-studio/workspace-view", "workspace_id": "workspace",
            "source_id": "sqlite:/sample", "source_revision": "revision", "frame_revision": "one",
            "image": "native-frame", "mimeType": "image/jpeg", "width": 700, "height": 400,
        ]]
    }
}
