import Foundation
import XCTest
@testable import StudioMCP

final class MCPServerTests: XCTestCase {
    func testCatalogHasAllSixtyTwoUniqueDocumentedTools() {
        XCTAssertEqual(MCPToolCatalog.tools.count, 62)
        XCTAssertEqual(Set(MCPToolCatalog.names).count, 62)
        XCTAssertTrue(MCPToolCatalog.names.contains("studio_status"))
        XCTAssertTrue(MCPToolCatalog.names.contains("studio_test_speech"))
        for tool in MCPToolCatalog.tools {
            let schema = tool.json["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object")
            XCTAssertTrue(schema?["properties"] is [String: Any])
        }

        let connectSchema = MCPToolCatalog.tool(named: "studio_connect_context")?.json["inputSchema"] as? [String: Any]
        let connectProperties = connectSchema?["properties"] as? [String: Any]
        XCTAssertTrue(connectProperties?["client_task_id"] is [String: Any])
        XCTAssertTrue(connectProperties?["workspace_id"] is [String: Any])

        let launchSchema = MCPToolCatalog.tool(named: "studio_launch")?.json["inputSchema"] as? [String: Any]
        let launchProperties = launchSchema?["properties"] as? [String: Any]
        XCTAssertTrue(launchProperties?["wait_ms"] is [String: Any])
        XCTAssertNil(launchProperties?["wait_timeout_ms"])

        let updateSchema = MCPToolCatalog.tool(named: "studio_update_workspace")?.json["inputSchema"] as? [String: Any]
        let updateProperties = updateSchema?["properties"] as? [String: Any]
        let updateRequired = updateSchema?["required"] as? [String]
        XCTAssertTrue(updateProperties?["workspace_id"] is [String: Any])
        XCTAssertTrue(updateProperties?["expected_view_revision"] is [String: Any])
        XCTAssertEqual((updateProperties?["expected_view_revision"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertTrue(updateRequired?.contains("request_id") == true)

        let sizingSchema = MCPToolCatalog.tool(named: "studio_set_node_sizing")?.json["inputSchema"] as? [String: Any]
        let sizingProperties = sizingSchema?["properties"] as? [String: Any]
        XCTAssertEqual((sizingProperties?["metric"] as? [String: Any])?["enum"] as? [String], ["uniform", "fields", "rows", "relations"])
        XCTAssertEqual((sizingProperties?["persist"] as? [String: Any])?["type"] as? String, "boolean")

        for name in ["studio_manage_speech_assets", "studio_test_speech"] {
            let description = MCPToolCatalog.tool(named: name)?.json["description"] as? String
            XCTAssertFalse(description?.hasPrefix("Unavailable in this app build") == true, name)
        }

        let annotationDescription = MCPToolCatalog.tool(named: "studio_annotate_view")?.json["description"] as? String
        XCTAssertFalse(annotationDescription?.hasPrefix("Unavailable in this app build") == true)

        let saveExplanation = MCPToolCatalog.tool(named: "studio_save_explanation")?.json["description"] as? String
        XCTAssertFalse(saveExplanation?.hasPrefix("Unavailable in this app build") == true)
        XCTAssertTrue(saveExplanation?.contains("only points that have actually appeared") == true)
        XCTAssertTrue(saveExplanation?.contains("never overwrites") == true)
        let openExplanation = MCPToolCatalog.tool(named: "studio_open_explanation")?.json["description"] as? String
        XCTAssertFalse(openExplanation?.hasPrefix("Unavailable in this app build") == true)
        XCTAssertTrue(openExplanation?.contains("dedicated offline tab") == true)
        let refreshExplanation = MCPToolCatalog.tool(named: "studio_prepare_explanation_refresh")?.json["description"] as? String
        XCTAssertFalse(refreshExplanation?.hasPrefix("Unavailable in this app build") == true)
        XCTAssertTrue(refreshExplanation?.contains("no old captions or narration") == true)
        let inspectArtifact = MCPToolCatalog.tool(named: "studio_inspect_artifact")?.json["description"] as? String
        XCTAssertTrue(inspectArtifact?.contains("fresh explanation-refresh draft") == true)
        XCTAssertTrue(inspectArtifact?.contains("exact table ID") == true)

        let exportTool = MCPToolCatalog.tool(named: "studio_export")?.json
        let exportDescription = exportTool?["description"] as? String
        let exportSchema = exportTool?["inputSchema"] as? [String: Any]
        let exportProperties = exportSchema?["properties"] as? [String: Any]
        let scopeSchema = exportProperties?["scope"] as? [String: Any]
        let scopeProperties = scopeSchema?["properties"] as? [String: Any]
        XCTAssertFalse(exportDescription?.hasPrefix("Unavailable in this app build") == true)
        XCTAssertTrue(exportDescription?.contains("never rerun as all_matching") == true)
        XCTAssertEqual((exportProperties?["object_type"] as? [String: Any])?["enum"] as? [String], ["table_rows", "query_result", "transcript"])
        XCTAssertEqual((scopeProperties?["kind"] as? [String: Any])?["enum"] as? [String], ["displayed", "captured", "all_matching"])
        XCTAssertTrue((scopeSchema?["required"] as? [String])?.contains("kind") == true)
        XCTAssertEqual((exportProperties?["format"] as? [String: Any])?["enum"] as? [String], ["csv", "json"])
        XCTAssertTrue((exportProperties?["overwrite"] as? [String: Any]) is [String: Any])
        XCTAssertTrue((exportProperties?["timeout_seconds"] as? [String: Any]) is [String: Any])
        XCTAssertTrue((exportSchema?["required"] as? [String])?.contains("request_id") == true)
        let exportAnnotations = exportTool?["annotations"] as? [String: Any]
        XCTAssertEqual(exportAnnotations?["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(exportAnnotations?["destructiveHint"] as? Bool, true)
        XCTAssertEqual(exportAnnotations?["openWorldHint"] as? Bool, true)

        let getJobDescription = MCPToolCatalog.tool(named: "studio_get_job")?.json["description"] as? String
        let cancelJobDescription = MCPToolCatalog.tool(named: "studio_cancel_job")?.json["description"] as? String
        XCTAssertTrue(getJobDescription?.contains("studio_export") == true)
        XCTAssertTrue(getJobDescription?.contains("speech-asset install") == true)
        XCTAssertTrue(cancelJobDescription?.contains("speech-test job") == true)

        let followTool = MCPToolCatalog.tool(named: "studio_follow_record")?.json
        let followDescription = followTool?["description"] as? String
        let followSchema = followTool?["inputSchema"] as? [String: Any]
        let followProperties = followSchema?["properties"] as? [String: Any]
        XCTAssertFalse(followDescription?.hasPrefix("Unavailable in this app build") == true)
        XCTAssertTrue(followSchema?["oneOf"] is [[String: Any]])
        XCTAssertTrue(followProperties?["relation_id"] is [String: Any])
        XCTAssertTrue(followProperties?["mapping_id"] is [String: Any])
        XCTAssertNil(followProperties?["limit"])
        XCTAssertEqual((followProperties?["direction"] as? [String: Any])?["enum"] as? [String], ["incoming", "outgoing"])
        XCTAssertEqual((followProperties?["display_intent"] as? [String: Any])?["enum"] as? [String], ["show"])

        let mappingTool = MCPToolCatalog.tool(named: "studio_list_record_mappings")?.json
        let mappingDescription = mappingTool?["description"] as? String
        let mappingSchema = mappingTool?["inputSchema"] as? [String: Any]
        let mappingProperties = mappingSchema?["properties"] as? [String: Any]
        XCTAssertTrue(mappingDescription?.contains("studio_follow_record") == true)
        XCTAssertTrue(mappingDescription?.contains("not database-declared relationships") == true)
        XCTAssertEqual((mappingProperties?["limit"] as? [String: Any])?["maximum"] as? Int, 5)
        XCTAssertTrue(mappingProperties?["mapping_id"] is [String: Any])
        XCTAssertEqual((mappingTool?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)

        let recordGraphTool = MCPToolCatalog.tool(named: "studio_show_record_graph")?.json
        let recordGraphDescription = recordGraphTool?["description"] as? String
        let recordGraphSchema = recordGraphTool?["inputSchema"] as? [String: Any]
        let recordGraphProperties = recordGraphSchema?["properties"] as? [String: Any]
        let seeds = recordGraphProperties?["seed_records"] as? [String: Any]
        XCTAssertFalse(recordGraphDescription?.hasPrefix("Unavailable in this app build") == true)
        XCTAssertTrue(recordGraphDescription?.contains("does not inspect arbitrary seed records") == true)
        XCTAssertEqual(seeds?["maxItems"] as? Int, 1)
        XCTAssertNil(recordGraphProperties?["max_hops"])
        XCTAssertNil(recordGraphProperties?["node_budget"])
        XCTAssertNil(recordGraphProperties?["expected_view_revision"])
        XCTAssertEqual((recordGraphProperties?["direction"] as? [String: Any])?["enum"] as? [String], ["incoming", "outgoing", "both"])

        let presentationTool = MCPToolCatalog.tool(named: "studio_start_presentation")?.json
        let presentationDescription = presentationTool?["description"] as? String
        let presentationSchema = presentationTool?["inputSchema"] as? [String: Any]
        let presentationProperties = presentationSchema?["properties"] as? [String: Any]
        XCTAssertTrue(presentationDescription?.contains("saved source preference") == true)
        XCTAssertEqual((presentationProperties?["narration_mode"] as? [String: Any])?["default"] as? String, "app_default")

        let speechDescription = MCPToolCatalog.tool(named: "studio_get_speech")?.json["description"] as? String
        XCTAssertTrue(speechDescription?.contains("provider actually speaking") == true)
        XCTAssertTrue(speechDescription?.contains("completed asset download is not a successful model startup") == true)
        let configureSpeechDescription = MCPToolCatalog.tool(named: "studio_configure_speech")?.json["description"] as? String
        XCTAssertTrue(configureSpeechDescription?.contains("Enable or disable Graph Studio narration") == true)
        XCTAssertTrue(configureSpeechDescription?.contains("voice, provider, or speed selection") == true)

        let manageSpeechTool = MCPToolCatalog.tool(named: "studio_manage_speech_assets")?.json
        let manageSpeechDescription = manageSpeechTool?["description"] as? String
        let manageSpeechSchema = manageSpeechTool?["inputSchema"] as? [String: Any]
        let manageSpeechProperties = manageSpeechSchema?["properties"] as? [String: Any]
        XCTAssertTrue(manageSpeechDescription?.contains("offer never starts a transfer") == true)
        XCTAssertEqual((manageSpeechProperties?["package_id"] as? [String: Any])?["enum"] as? [String], ["pocket-tts-english-2026-09-alba"])
        XCTAssertEqual((manageSpeechProperties?["action"] as? [String: Any])?["enum"] as? [String], ["offer", "install", "cancel", "retry"])

        let testSpeechTool = MCPToolCatalog.tool(named: "studio_test_speech")?.json
        let testSpeechDescription = testSpeechTool?["description"] as? String
        let testSpeechSchema = testSpeechTool?["inputSchema"] as? [String: Any]
        let testSpeechProperties = testSpeechSchema?["properties"] as? [String: Any]
        XCTAssertTrue(testSpeechDescription?.contains("exact visible workspace") == true)
        XCTAssertTrue(testSpeechDescription?.contains("never stops or replaces another narrator") == true)
        XCTAssertEqual((testSpeechProperties?["voice_id"] as? [String: Any])?["enum"] as? [String], ["app_default", "macos", "alba"])
        XCTAssertEqual((testSpeechProperties?["diagnostic_id"] as? [String: Any])?["enum"] as? [String], ["short_sample"])

        let groupsDescription = MCPToolCatalog.tool(named: "studio_set_groups")?.json["description"] as? String
        XCTAssertFalse(groupsDescription?.hasPrefix("Unavailable in this app build") == true)
        let groupsSchema = MCPToolCatalog.tool(named: "studio_set_groups")?.json["inputSchema"] as? [String: Any]
        let groupsProperties = groupsSchema?["properties"] as? [String: Any]
        XCTAssertTrue(groupsProperties?["restore_authored"] is [String: Any])
    }

    func testLegacyInitializeAndToolDiscovery() throws {
        let dispatcher = RecordingDispatcher()
        let server = MCPServer(dispatcher: dispatcher, clientID: "task-1", workingDirectory: "/tmp/project")

        let initialize = try server.handleMessage(json([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "clientInfo": ["name": "Claude Code", "version": "2.1"],
                "capabilities": ["tools": [:]],
            ],
        ]))
        let initializeResult = object(initialize)["result"] as? [String: Any]
        XCTAssertEqual(initializeResult?["protocolVersion"] as? String, "2025-11-25")

        XCTAssertNil(server.handleMessage(json(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        let list = try server.handleMessage(json([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ]))
        let response = object(list)
        let tools = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 62)
    }

    func testToolCallCarriesTaskAndSourceContext() throws {
        let dispatcher = RecordingDispatcher()
        let server = MCPServer(dispatcher: dispatcher, clientID: "task-abc", workingDirectory: "/repo/demo")
        try initializeLegacy(server)

        let response = try server.handleMessage(json([
            "jsonrpc": "2.0",
            "id": "call-1",
            "method": "tools/call",
            "params": [
                "name": "studio_connect_context",
                "arguments": ["project_path": "/repo/demo", "known_binding": ["source_id": "db-1"]],
            ],
        ]))
        XCTAssertEqual((object(response)["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(dispatcher.lastCall?.name, "studio_connect_context")
        XCTAssertEqual(dispatcher.lastCall?.clientID, "task-abc")
        XCTAssertEqual(dispatcher.lastCall?.workingDirectory, "/repo/demo")
        XCTAssertEqual(dispatcher.lastCall?.arguments["project_path"] as? String, "/repo/demo")
    }

    func testModernDiscoveryAndPerRequestMetadata() throws {
        let dispatcher = RecordingDispatcher()
        let server = MCPServer(dispatcher: dispatcher, clientID: "task-modern")
        let meta: [String: Any] = [
            "io.modelcontextprotocol/protocolVersion": MCPServer.modernProtocolVersion,
            "io.modelcontextprotocol/clientInfo": ["name": "Codex", "version": "1"],
            "io.modelcontextprotocol/clientCapabilities": ["tools": [:]],
        ]

        let discovery = try server.handleMessage(json([
            "jsonrpc": "2.0", "id": "discover", "method": "server/discover", "params": ["_meta": meta],
        ]))
        let discoveryResult = object(discovery)["result"] as? [String: Any]
        XCTAssertEqual(discoveryResult?["resultType"] as? String, "complete")
        XCTAssertTrue((discoveryResult?["supportedVersions"] as? [String])?.contains(MCPServer.modernProtocolVersion) == true)

        let call = try server.handleMessage(json([
            "jsonrpc": "2.0",
            "id": "status-call",
            "method": "tools/call",
            "params": ["_meta": meta, "name": "studio_status", "arguments": [:]],
        ]))
        XCTAssertEqual(dispatcher.lastCall?.clientName, "Codex")
        XCTAssertEqual(dispatcher.lastCall?.name, "studio_status")
        XCTAssertNotNil(object(call)["result"])
    }

    func testRejectsToolCallsBeforeHandshakeAndUnknownNames() throws {
        let dispatcher = RecordingDispatcher()
        let server = MCPServer(dispatcher: dispatcher)
        let beforeHandshake = try server.handleMessage(json([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:],
        ]))
        XCTAssertEqual((object(beforeHandshake)["error"] as? [String: Any])?["code"] as? Int, -32002)

        try initializeLegacy(server)
        let unknown = try server.handleMessage(json([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "studio_arbitrary_method", "arguments": [:]],
        ]))
        XCTAssertEqual((object(unknown)["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNil(dispatcher.lastCall)
    }

    func testToolCallsAreValidatedAgainstCatalogBeforeDispatch() throws {
        let dispatcher = RecordingDispatcher()
        let server = MCPServer(dispatcher: dispatcher, clientID: "schema-validation")
        try initializeLegacy(server)

        let appContext: [String: Any] = ["context_id": "context:test"]
        let cases: [(name: String, arguments: [String: Any], path: String, keyword: String)] = [
            ("studio_scan_project", appContext, "/project_path", "required"),
            ("studio_set_layout", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "layout-empty",
            ]) { _, new in new }, "/", "anyOf"),
            ("studio_set_layout", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "layout-enum", "left_pane": "left",
            ]) { _, new in new }, "/left_pane", "enum"),
            ("studio_set_layout", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "layout-bool-number", "split_fraction": true,
            ]) { _, new in new }, "/split_fraction", "type"),
            ("studio_set_camera", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "camera-half-pan", "pan_x": 12,
            ]) { _, new in new }, "/", "anyOf"),
            ("studio_update_workspace", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "workspace-background",
                "changes": ["activation_intent": "background"],
            ]) { _, new in new }, "/changes/activation_intent", "enum"),
            ("studio_update_workspace", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "workspace-unknown-change",
                "changes": ["activate": true, "rename": "ignored"],
            ]) { _, new in new }, "/changes/rename", "additionalProperties"),
            ("studio_arrange_tables", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "arrange-position-many", "operation": "position",
                "table_ids": ["a", "b"], "x": 1, "y": 2,
            ]) { _, new in new }, "/table_ids", "maxItems"),
            ("studio_arrange_tables", appContext.merging([
                "workspace_id": "workspace:test", "request_id": "arrange-empty",
            ]) { _, new in new }, "/table_ids", "required"),
            ("studio_find_relations", appContext.merging([
                "workspace_id": "workspace:test", "table_ids": [true],
            ]) { _, new in new }, "/table_ids/0", "type"),
            ("studio_list_record_mappings", appContext.merging(["limit": 6]) { _, new in new }, "/limit", "maximum"),
            ("studio_connect_context", ["resume_context_id": "context:prior"], "/resume_token", "dependentRequired"),
            ("studio_follow_record", appContext.merging([
                "request_id": "follow-both", "relation_id": "relation:1", "mapping_id": "mapping:1",
            ]) { _, new in new }, "/", "oneOf"),
            ("studio_show_record_graph", appContext.merging([
                "request_id": "record-extra", "seed_records": [["record_id": "record:1", "extra": true]],
            ]) { _, new in new }, "/seed_records/0/extra", "additionalProperties"),
            ("studio_update_annotations", appContext.merging([
                "request_id": "annotation-pattern", "expected_metadata_revision": "not-a-revision",
            ]) { _, new in new }, "/expected_metadata_revision", "pattern"),
        ]

        for (index, testCase) in cases.enumerated() {
            let response = try server.handleMessage(json([
                "jsonrpc": "2.0", "id": "invalid-\(index)", "method": "tools/call",
                "params": ["name": testCase.name, "arguments": testCase.arguments],
            ]))
            let error = object(response)["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? Int, -32602, testCase.name)
            let data = error?["data"] as? [String: Any]
            XCTAssertEqual(data?["code"] as? String, "INVALID_ARGUMENT", testCase.name)
            XCTAssertEqual(data?["tool"] as? String, testCase.name, testCase.name)
            XCTAssertEqual(data?["path"] as? String, testCase.path, testCase.name)
            XCTAssertEqual(data?["keyword"] as? String, testCase.keyword, testCase.name)
            XCTAssertNil(dispatcher.lastCall, "Invalid \(testCase.name) call reached the dispatcher")
        }

        let valid = try server.handleMessage(json([
            "jsonrpc": "2.0", "id": "valid-camera", "method": "tools/call",
            "params": [
                "name": "studio_set_camera",
                "arguments": appContext.merging([
                    "workspace_id": "workspace:test", "request_id": "camera-valid", "zoom": 1.0,
                    "legacy_client_hint": "preserved",
                ]) { _, new in new },
            ],
        ]))
        XCTAssertEqual((object(valid)["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(dispatcher.lastCall?.name, "studio_set_camera")
        XCTAssertEqual(dispatcher.lastCall?.arguments["legacy_client_hint"] as? String, "preserved")

        let validRevisionCall = try server.handleMessage(json([
            "jsonrpc": "2.0", "id": "valid-revision", "method": "tools/call",
            "params": [
                "name": "studio_update_annotations",
                "arguments": appContext.merging([
                    "request_id": "annotation-valid-pattern", "expected_metadata_revision": String(repeating: "a", count: 64),
                ]) { _, new in new },
            ],
        ]))
        XCTAssertEqual((object(validRevisionCall)["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(dispatcher.lastCall?.name, "studio_update_annotations")

        let toolCatalog = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools.map { ($0.name, $0) })
        let relationSchema = toolCatalog["studio_find_relations"]?.json["inputSchema"] as? [String: Any]
        let relationProperties = relationSchema?["properties"] as? [String: Any]
        XCTAssertNil(relationProperties?["limit"], "An ignored limit must not be advertised")
    }

    func testMalformedJSONReturnsParseError() throws {
        let server = MCPServer(dispatcher: RecordingDispatcher())
        let response = try server.handleMessage(Data("{".utf8))
        XCTAssertEqual((object(response)["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testStdioEOFNotifiesDispatcherForClientCleanup() throws {
        let input = Pipe()
        try input.fileHandleForWriting.close()
        let dispatcher = RecordingDispatcher()
        let server = MCPServer(dispatcher: dispatcher, clientID: "client-eof")

        try MCPStdioRunner(server: server).run(
            input: input.fileHandleForReading,
            output: FileHandle.nullDevice
        )

        XCTAssertEqual(dispatcher.disconnectedClientIDs, ["client-eof"])
    }

    private func initializeLegacy(_ server: MCPServer) throws {
        _ = try server.handleMessage(json([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "test", "version": "1"]],
        ]))
        _ = server.handleMessage(json(["jsonrpc": "2.0", "method": "notifications/initialized"]))
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

private final class RecordingDispatcher: MCPToolDispatcher {
    private(set) var lastCall: MCPToolCall?
    private(set) var disconnectedClientIDs: [String] = []

    func dispatch(_ call: MCPToolCall) -> [String: Any] {
        lastCall = call
        return ["content": [["type": "text", "text": "ok"]], "isError": false]
    }

    func clientDisconnected(clientID: String) {
        disconnectedClientIDs.append(clientID)
    }
}
