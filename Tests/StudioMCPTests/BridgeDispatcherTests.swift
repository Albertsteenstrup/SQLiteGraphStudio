import Foundation
import XCTest
@testable import StudioMCP

final class BridgeDispatcherTests: XCTestCase {
    func testStatusAndLaunchAreExplicitLocalActions() {
        let transport = FakeBridgeTransport()
        let dispatcher = LocalMCPToolDispatcher(transport: transport)
        let status = dispatcher.dispatch(call("studio_status", arguments: [:]))
        XCTAssertEqual(status["isError"] as? Bool, false)
        XCTAssertEqual(transport.statusCallCount, 1)
        XCTAssertEqual(transport.launchCallCount, 0)

        let launch = dispatcher.dispatch(call("studio_launch", arguments: [
            "foreground_intent": false,
            "wait_timeout_ms": 20,
        ]))
        XCTAssertEqual(launch["isError"] as? Bool, false)
        XCTAssertEqual(transport.launchCallCount, 1)
        XCTAssertEqual(transport.lastForeground, false)
        XCTAssertEqual(transport.lastTimeoutMilliseconds, 1_000)
    }

    func testNonLocalToolsAreForwardedWithContextAndSnakeCaseArguments() {
        let transport = FakeBridgeTransport()
        let dispatcher = LocalMCPToolDispatcher(transport: transport)
        _ = dispatcher.dispatch(call("studio_describe_schema", arguments: [
            "source_id": "source-1",
            "workspace_id": "workspace-1",
            "table_ids": ["table-1"],
        ], contextID: "ctx-1"))

        XCTAssertEqual(transport.lastCall?.name, "studio_describe_schema")
        XCTAssertEqual(transport.lastCall?.contextID, "ctx-1")
        XCTAssertEqual(transport.lastCall?.arguments["source_id"] as? String, "source-1")
        XCTAssertEqual(transport.lastCall?.arguments["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(transport.lastCall?.arguments["table_ids"] as? [String], ["table-1"])
    }

    func testConnectContextAddsProjectPathWhenCallerOmittedIt() {
        let transport = FakeBridgeTransport()
        let dispatcher = LocalMCPToolDispatcher(transport: transport)
        _ = dispatcher.dispatch(call("studio_connect_context", arguments: [:]))
        XCTAssertEqual(transport.lastCall?.arguments["project_path"] as? String, "/repo")
    }

    func testStdioClientDisconnectIsForwardedToPrivateAppBridge() {
        let transport = FakeBridgeTransport()
        let dispatcher = LocalMCPToolDispatcher(transport: transport)

        dispatcher.clientDisconnected(clientID: "client-1")

        XCTAssertEqual(transport.disconnectedClientIDs, ["client-1"])
    }

    func testLaterTaskCannotBorrowTheMostRecentlyConnectedContext() {
        let transport = FakeBridgeTransport()
        let dispatcher = LocalMCPToolDispatcher(transport: transport)
        _ = dispatcher.dispatch(call("studio_connect_context", arguments: ["client_task_id": "task-one"]))
        _ = dispatcher.dispatch(call("studio_get_view", arguments: ["workspace_id": "workspace-two"]))
        XCTAssertNil(transport.lastCall?.contextID)
    }

    func testAppToolsAdvertiseAnExplicitTaskContext() {
        let schema = MCPToolCatalog.tool(named: "studio_get_view")?.json["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        XCTAssertTrue(properties?["context_id"] is [String: Any])
        XCTAssertTrue((schema?["required"] as? [String])?.contains("context_id") == true)

        let status = MCPToolCatalog.tool(named: "studio_status")?.json["inputSchema"] as? [String: Any]
        XCTAssertFalse((status?["required"] as? [String])?.contains("context_id") == true)
    }

    private func call(
        _ name: String,
        arguments: [String: Any],
        contextID: String? = nil
    ) -> MCPToolCall {
        MCPToolCall(
            name: name,
            arguments: arguments,
            contextID: contextID,
            clientID: "client-1",
            clientName: "Test Client",
            clientVersion: "1",
            workingDirectory: "/repo"
        )
    }
}

private final class FakeBridgeTransport: MCPBridgeTransport {
    private(set) var statusCallCount = 0
    private(set) var launchCallCount = 0
    private(set) var lastForeground = true
    private(set) var lastTimeoutMilliseconds = 0
    private(set) var lastCall: MCPToolCall?
    private(set) var disconnectedClientIDs: [String] = []

    func status(clientID: String) -> [String: Any] {
        statusCallCount += 1
        return ["content": [["type": "text", "text": "status"]], "isError": false]
    }

    func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any] {
        launchCallCount += 1
        lastForeground = foreground
        lastTimeoutMilliseconds = timeoutMilliseconds
        return ["content": [["type": "text", "text": "launched"]], "isError": false]
    }

    func call(_ call: MCPToolCall, contextID: String?) -> [String: Any] {
        lastCall = call
        if call.name == "studio_connect_context" {
            return ["content": [["type": "text", "text": "connected"]],
                    "structuredContent": ["context_id": "task-one-context"], "isError": false]
        }
        return ["content": [["type": "text", "text": "forwarded"]], "isError": false]
    }

    func disconnect(clientID: String) {
        disconnectedClientIDs.append(clientID)
    }
}
