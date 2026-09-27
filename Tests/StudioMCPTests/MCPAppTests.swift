import Foundation
import XCTest
@testable import StudioMCP

final class MCPAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioMCPAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

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

    func testReviewToolNamesItsViewAndNeedsNoCodingTaskContext() throws {
        let tool = try XCTUnwrap(MCPToolCatalog.tool(named: SchemaReviewInlineView.toolName)?.json)
        let meta = tool["_meta"] as? [String: Any]
        XCTAssertEqual((meta?["ui"] as? [String: Any])?["resourceUri"] as? String, MCPAppResources.schemaReviewURI)
        XCTAssertEqual(meta?["ui/resourceUri"] as? String, MCPAppResources.schemaReviewURI)
        let schema = tool["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["path"])
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertTrue((tool["description"] as? String)?.contains("does not need to be running") == true)
    }

    func testServesOneSelfContainedViewThatNeverTouchesTheNetwork() throws {
        let server = try initializedServer()
        let list = try object(server.handleMessage(json(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])))
        let resources = (list["result"] as? [String: Any])?["resources"] as? [[String: Any]]
        XCTAssertEqual(resources?.map { $0["uri"] as? String }, [MCPAppResources.schemaReviewURI])
        XCTAssertEqual(resources?.first?["mimeType"] as? String, "text/html;profile=mcp-app")

        let read = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": MCPAppResources.schemaReviewURI],
        ])))
        let content = try XCTUnwrap(((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["mimeType"] as? String, "text/html;profile=mcp-app")
        XCTAssertEqual(((content["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["prefersBorder"] as? Bool, true)
        let html = try XCTUnwrap(content["text"] as? String)
        for handshake in ["ui/initialize", "ui/notifications/initialized", "ui/notifications/tool-result", "ui/notifications/size-changed"] {
            XCTAssertTrue(html.contains(handshake), handshake)
        }
        // The host's default sandbox allows no network, and review text must never become markup.
        for forbidden in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "fetch(", "XMLHttpRequest", "WebSocket", "<script src", "<link", "@import", "eval("] {
            XCTAssertFalse(html.contains(forbidden), forbidden)
        }
        // `hidden` is an HTML element property; on the SVG graph only the attribute hides it.
        XCTAssertFalse(html.contains(#"$("graph").hidden"#), "Toggle the graph's hidden attribute instead")

        let missing = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": ["uri": "ui://sqlite-graph-studio/other.html"],
        ])))
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32002)
    }

    func testShowsAReviewFromTheFileAloneWithAModelSummaryAndViewData() throws {
        try write(review(), to: "change.sgreview")
        let transport = UnusedTransport()
        let server = try initializedServer(transport: transport, workingDirectory: directory.path)
        let response = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": SchemaReviewInlineView.toolName, "arguments": ["path": "change.sgreview"]],
        ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(transport.calls, 0, "Showing a review must never contact the app")

        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("Schema review \"Sessions\" is shown inline (base → head)."))
        XCTAssertTrue(text.contains("3 changed tables: 1 new, 1 removed, 1 changed"))
        XCTAssertTrue(text.contains("users (+1 −1 ~1 ↔)"))
        XCTAssertTrue(text.contains("Author: Claude · Review session."))

        let overview = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(overview["format"] as? String, "sqlite-graph-studio/schema-review-view")
        XCTAssertEqual(overview["artifact"] as? String, "comparison")
        XCTAssertEqual(overview["overview"] as? String, text, "Claude Code shows the model structuredContent, so it carries the summary too")
        let sets = try XCTUnwrap(overview["changeSets"] as? [[String: Any]])
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?["label"] as? String, "legacy_tokens")
        XCTAssertEqual(sets.first?["tables"] as? Int, 3)
        XCTAssertEqual(sets.first?["kind"] as? String, "modified", "A set of mixed changes reads as changed")
        XCTAssertNil(overview["tables"], "The view fetches tables and fields itself")

        // The view asks for what it draws with a tool the model never sees.
        let detailResponse = try object(server.handleMessage(json([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": SchemaReviewAppTools.detailToolName, "arguments": ["path": "change.sgreview"]],
        ])))
        let view = try XCTUnwrap((detailResponse["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        XCTAssertEqual(view["format"] as? String, "sqlite-graph-studio/schema-review-detail")
        XCTAssertEqual(transport.calls, 0)
        let tables = try XCTUnwrap(view["tables"] as? [[String: Any]])
        let kinds = Dictionary(uniqueKeysWithValues: tables.map { ($0["id"] as! String, $0["kind"] as! String) })
        XCTAssertEqual(kinds, ["legacy_tokens": "removed", "sessions": "added", "users": "modified", "teams": "unchanged"])
        XCTAssertNil(kinds["projects"], "Unrelated unchanged tables stay out of the view")
        XCTAssertEqual(tables.first { $0["id"] as? String == "teams" }?["context"] as? Bool, true)

        let users = try XCTUnwrap(tables.first { $0["id"] as? String == "users" })
        let columns = try XCTUnwrap(users["columns"] as? [[String: Any]])
        // Keys first, then changed fields with removed ones last, as the app's cards list them.
        XCTAssertEqual(columns.map { $0["name"] as? String }, ["id", "team_id", "email", "active", "nickname"])
        XCTAssertEqual(columns.map { $0["kind"] as? String }, ["unchanged", "unchanged", "modified", "added", "removed"])
        XCTAssertEqual(columns.map { $0["foreignKey"] as? Bool }, [false, true, false, false, false])
        XCTAssertEqual(view["changeSets"] as? [[String]], [["legacy_tokens", "sessions", "users"]])
        XCTAssertEqual(columns[2]["before"] as? String, "TEXT · NULL")
        XCTAssertEqual(columns[2]["description"] as? String, "TEXT · NOT NULL · DEFAULT ''")
        let definitions = try XCTUnwrap(users["definitionChanges"] as? [[String: Any]])
        XCTAssertEqual(definitions.map { $0["label"] as? String }, ["Index users_email"])

        let relations = try XCTUnwrap(view["relations"] as? [[String: Any]])
        let relationKinds = Dictionary(uniqueKeysWithValues: relations.map { ($0["id"] as! String, $0["kind"] as! String) })
        XCTAssertEqual(relationKinds, ["fk_tokens": "removed", "fk_sessions": "added", "fk_team": "unchanged"])
    }

    func testProposalsAreLabelledAndLargeTablesKeepEveryChangedField() throws {
        var document = review()
        var before = document["before"] as! [String: Any]
        var after = document["after"] as! [String: Any]
        var wideBefore = table("wide", columns: [column("id", pk: 1)] + (0..<100).map { column("f\($0)") })
        var wideAfter = wideBefore
        var afterColumns = wideAfter["columns"] as! [[String: Any]]
        afterColumns[90]["type"] = "VARCHAR(40)"
        wideAfter["columns"] = afterColumns
        wideBefore["metadata"] = [:]
        wideAfter["metadata"] = [:]
        before["tables"] = (before["tables"] as! [[String: Any]]) + [wideBefore]
        after["tables"] = (after["tables"] as! [[String: Any]]) + [wideAfter]
        document["before"] = before
        document["after"] = after
        let baseline = try JSONDecoder().decode(SchemaReviewInlineView.Snapshot.self, from: JSONSerialization.data(withJSONObject: before))
        document["proposal"] = ["baseFingerprint": try SchemaReviewInlineView.fingerprint(baseline),
                                "planFingerprint": String(repeating: "1", count: 64)]
        try write(document, to: "plan.sgpreview")

        let path = directory.appendingPathComponent("plan.sgpreview").path
        let result = SchemaReviewInlineView.result(path: path, workingDirectory: "/")
        let overview = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(overview["artifact"] as? String, "proposal")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertTrue(text?.hasPrefix("Proposed schema changes \"Sessions\" are shown inline (not applied; based on base).") == true)

        let view = try XCTUnwrap(SchemaReviewInlineView.detail(path: path, workingDirectory: "/")["structuredContent"] as? [String: Any])
        let wide = try XCTUnwrap((view["tables"] as? [[String: Any]])?.first { $0["id"] as? String == "wide" })
        let names = (wide["columns"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(names.count, SchemaReviewInlineView.maximumColumnsPerTable)
        XCTAssertTrue(names.contains("f89"), "A changed field past the cap must still be shown")
        XCTAssertEqual(wide["hiddenColumns"] as? Int, 101 - SchemaReviewInlineView.maximumColumnsPerTable)
    }

    func testRejectsFilesThatAreNotValidReviewsWithoutContactingTheApp() throws {
        func errorCode(_ path: String) -> String? {
            let result = SchemaReviewInlineView.result(path: path, workingDirectory: directory.path)
            XCTAssertEqual(result["isError"] as? Bool, true, path)
            return ((result["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.json"))
        XCTAssertEqual(errorCode("notes.json"), "INVALID_ARGUMENT")
        XCTAssertEqual(errorCode("missing.sgreview"), "OBJECT_NOT_FOUND")

        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.sgreview"))
        XCTAssertEqual(errorCode("broken.sgreview"), "INVALID_ARTIFACT")

        var mixedEngines = review()
        var after = mixedEngines["after"] as! [String: Any]
        after["engine"] = "postgresql"
        mixedEngines["after"] = after
        try write(mixedEngines, to: "engines.sgreview")
        XCTAssertEqual(errorCode("engines.sgreview"), "INVALID_ARTIFACT")

        var duplicate = review()
        var before = duplicate["before"] as! [String: Any]
        before["tables"] = (before["tables"] as! [[String: Any]]) + [table("teams", columns: [column("id", pk: 1)])]
        duplicate["before"] = before
        try write(duplicate, to: "duplicate.sgreview")
        XCTAssertEqual(errorCode("duplicate.sgreview"), "INVALID_ARTIFACT")

        var spoofed = review()
        spoofed["author"] = ["tool": "claude", "session": "fine\u{202E}desrever"]
        try write(spoofed, to: "author.sgreview")
        XCTAssertEqual(errorCode("author.sgreview"), "INVALID_ARTIFACT")
    }

    func testHubChangesSummarizeUnchangedNeighboursAndGroupIdenticalChanges() throws {
        // A users table referenced from 20 unchanged tables, plus 4 tables that each
        // gain the same audit field and reference to it.
        let hub = table("app_user", columns: [column("id", type: "bigint", pk: 1), column("email")])
        var hubAfter = hub
        hubAfter["columns"] = (hub["columns"] as! [[String: Any]]) + [column("mfa_enrolled_at", type: "timestamptz")]
        let readers = (0..<20).map { table(String(format: "reader_%02d", $0), columns: [column("id", type: "bigint", pk: 1), column("user_id", type: "bigint")]) }
        let readerLinks = (0..<20).map { relation(String(format: "fk_reader_%02d", $0), String(format: "reader_%02d", $0), "user_id", "app_user") }
        let audited = (0..<4).map { table("audited_\($0)", columns: [column("id", type: "bigint", pk: 1)]) }
        let auditedAfter = audited.map { original -> [String: Any] in
            var copy = original
            copy["columns"] = (original["columns"] as! [[String: Any]]) + [column("updated_by_user_id", type: "bigint")]
            return copy
        }
        let auditLinks = (0..<4).map { relation("fk_audited_\($0)", "audited_\($0)", "updated_by_user_id", "app_user") }
        try write([
            "version": 1, "title": "Hub", "baseRef": "base", "headRef": "head", "notes": [],
            "before": ["version": 1, "engine": "postgresql", "tables": [hub] + readers + audited, "relations": readerLinks],
            "after": ["version": 1, "engine": "postgresql", "tables": [hubAfter] + readers + auditedAfter, "relations": readerLinks + auditLinks],
        ], to: "hub.sgreview")

        let path = directory.appendingPathComponent("hub.sgreview").path
        let result = SchemaReviewInlineView.result(path: path, workingDirectory: "/")
        let view = try XCTUnwrap(SchemaReviewInlineView.detail(path: path, workingDirectory: "/")["structuredContent"] as? [String: Any])
        // Hosts that show the model structuredContent get the summary, not the hub's links.
        let overview = try JSONSerialization.data(withJSONObject: try XCTUnwrap(result["structuredContent"]))
        let detail = try JSONSerialization.data(withJSONObject: view)
        XCTAssertLessThan(overview.count, 2_000, String(decoding: overview, as: UTF8.self))
        XCTAssertGreaterThan(detail.count, overview.count * 3)
        let tables = try XCTUnwrap(view["tables"] as? [[String: Any]])
        XCTAssertEqual(Set(tables.compactMap { $0["id"] as? String }), Set(["app_user"] + (0..<4).map { "audited_\($0)" }),
                       "Only changed tables are drawn once related tables exceed the limit")
        XCTAssertEqual((view["omitted"] as? [String: Any])?["relatedTables"] as? Int, 20)
        XCTAssertEqual((view["relations"] as? [[String: Any]])?.count, 4, "Only the changed relations are drawn")

        let links = try XCTUnwrap(tables.first { $0["id"] as? String == "app_user" }?["unchangedLinks"] as? [String: Any])
        XCTAssertEqual(links["relations"] as? Int, 20)
        XCTAssertEqual(links["tables"] as? Int, 20)
        XCTAssertEqual(links["drawn"] as? Bool, false)
        let first = try XCTUnwrap((links["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["name"] as? String, "reader_00")
        XCTAssertEqual(first["direction"] as? String, "referencedBy")
        XCTAssertEqual(first["columns"] as? [String], ["user_id"])

        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("4 tables share one change: + updated_by_user_id bigint · + → app_user."), text)
        XCTAssertTrue(text.contains("20 related unchanged tables are summarized"), text)
    }

    func testChangeGroupsKeepDifferentFieldAndDefinitionEditsSeparate() throws {
        let base = (0..<9).map { table("item_\($0)", columns: [column("id", type: "INTEGER", pk: 1), column("status")],
                                      metadata: $0 >= 6 ? ["index:status_\($0)": "CREATE INDEX status_\($0) ON item_\($0)(status)"] : [:]) }
        let revised = base.enumerated().map { index, original -> [String: Any] in
            var copy = original
            if index < 6 {
                var columns = original["columns"] as! [[String: Any]]
                columns[1] = column("status", type: index < 3 ? "INTEGER" : ["BOOLEAN", "VARCHAR(20)", "DATE"][index - 3])
                copy["columns"] = columns
            } else {
                copy["metadata"] = ["index:status_\(index)": "CREATE UNIQUE INDEX status_\(index) ON item_\(index)(status)"]
            }
            return copy
        }
        try write([
            "version": 1, "title": "Distinct edits", "baseRef": "base", "headRef": "head", "notes": [],
            "before": ["version": 1, "engine": "sqlite", "tables": base, "relations": []],
            "after": ["version": 1, "engine": "sqlite", "tables": revised, "relations": []],
        ], to: "distinct.sgreview")
        let result = SchemaReviewInlineView.result(path: "distinct.sgreview", workingDirectory: directory.path)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("3 tables share one change: ~ status."), text)
        XCTAssertFalse(text.contains("6 tables share one change"), text)
        XCTAssertFalse(text.contains("3 tables share one change: ~ definitions."), text)
    }

    // MARK: App-only tools

    func testViewToolsAreListedForEveryClientButMarkedForTheViewOnly() throws {
        // Claude Code renders views without declaring the MCP Apps extension, so the view's
        // tools can't depend on it; visibility keeps them out of the model's list instead.
        let server = try initializedServer()
        let response = object(try server.handleMessage(json(["jsonrpc": "2.0", "id": 9, "method": "tools/list"])))
        let tools = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in (tool["name"] as? String).map { ($0, tool) } })
        for name in SchemaReviewAppTools.names {
            let meta = try XCTUnwrap(byName[name]?["_meta"] as? [String: Any], name)
            XCTAssertEqual((meta["ui"] as? [String: Any])?["visibility"] as? [String], ["app"], name)
        }
        XCTAssertNotNil(byName[SchemaReviewInlineView.toolName])
    }

    func testViewToolsNeedNoCodingTaskContext() throws {
        for name in SchemaReviewAppTools.names {
            let tool = try XCTUnwrap(MCPToolCatalog.tool(named: name), name)
            XCTAssertEqual((tool.json["inputSchema"] as? [String: Any])?["required"] as? [String], ["path"], name)
        }
    }

    func testFrameToolAllowsLinkedTableSelection() throws {
        let schema = try XCTUnwrap(MCPToolCatalog.tool(named: SchemaReviewAppTools.frameToolName)?.json["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        let item = try XCTUnwrap(actions["items"] as? [String: Any])
        let actionProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let type = try XCTUnwrap(actionProperties["type"] as? [String: Any])
        XCTAssertTrue((type["enum"] as? [String])?.contains("select") == true)
        XCTAssertEqual((actionProperties["table"] as? [String: Any])?["type"] as? String, "string")
    }

    func testOpenViewCannotMixAnOlderSummaryWithAReplacedReview() throws {
        let path = "change.sgreview"
        try write(review(), to: path)
        let original = try XCTUnwrap(SchemaReviewInlineView.result(path: path, workingDirectory: directory.path)["structuredContent"] as? [String: Any])
        let revision = try XCTUnwrap(original["revision"] as? String)
        XCTAssertFalse(revision.isEmpty)
        let detail = SchemaReviewInlineView.detail(path: path, workingDirectory: directory.path, revision: revision)
        XCTAssertEqual(detail["isError"] as? Bool, false)

        var updated = review()
        updated["title"] = "Revised review"
        try JSONSerialization.data(withJSONObject: updated).write(to: directory.appendingPathComponent(path), options: .atomic)

        XCTAssertEqual(errorCode(SchemaReviewInlineView.detail(path: path, workingDirectory: directory.path, revision: revision)),
                       "REVIEW_CHANGED")
        XCTAssertEqual(errorCode(SchemaReviewAppTools.frame(arguments: ["path": path, "revision": revision],
                                                         workingDirectory: directory.path, renderer: renderer(executable: nil))),
                       "REVIEW_CHANGED", "A stale view must fail before drawing the replacement")

        let reopened = try XCTUnwrap(SchemaReviewInlineView.result(path: path, workingDirectory: directory.path)["structuredContent"] as? [String: Any])
        let newRevision = try XCTUnwrap(reopened["revision"] as? String)
        XCTAssertNotEqual(newRevision, revision)
        XCTAssertEqual(reopened["title"] as? String, "Revised review")
        XCTAssertEqual(SchemaReviewInlineView.detail(path: path, workingDirectory: directory.path,
                                                    revision: newRevision)["isError"] as? Bool, false)
    }

    func testFramesExplainAMissingOrBusyRenderer() throws {
        try write(review(), to: "change.sgreview")
        let arguments: [String: Any] = ["path": "change.sgreview"]
        let missing = renderer(executable: nil)
        XCTAssertEqual(errorCode(SchemaReviewAppTools.frame(arguments: arguments, workingDirectory: directory.path, renderer: missing)),
                       "RENDERER_UNAVAILABLE")

        // Other sessions hold every slot on the machine.
        let slots = directory.appendingPathComponent("busy", isDirectory: true)
        let held = (0..<SchemaReviewRenderer.slotCount).compactMap { _ in RendererSlot.acquire(in: slots, count: SchemaReviewRenderer.slotCount) }
        defer { held.forEach { $0.release() } }
        XCTAssertEqual(held.count, SchemaReviewRenderer.slotCount)
        let busy = renderer(executable: try fakeRenderer(), slots: slots)
        XCTAssertEqual(errorCode(SchemaReviewAppTools.frame(arguments: arguments, workingDirectory: directory.path, renderer: busy)),
                       "RENDERER_BUSY")
        XCTAssertFalse(busy.isRunning)
    }

    func testRendererStartsOnDemandStopsWhenIdleAndFreesItsSlot() throws {
        try write(review(), to: "change.sgreview")
        let slots = directory.appendingPathComponent("slots", isDirectory: true)
        let renderer = renderer(executable: try fakeRenderer(), slots: slots, idleTimeout: 0.3)
        let arguments: [String: Any] = ["path": "change.sgreview", "width": 640, "height": 400, "actions": [["type": "step", "direction": 1]]]
        let result = SchemaReviewAppTools.frame(arguments: arguments, workingDirectory: directory.path, renderer: renderer)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let image = try XCTUnwrap((result["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(image["type"] as? String, "image")
        XCTAssertEqual(image["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(image["data"] as? String, "AAAA")
        let state = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(state["sets"] as? Int, 2)
        XCTAssertEqual(state["setTables"] as? [[String]], [["users"], ["teams"]])
        XCTAssertTrue(renderer.isRunning)
        let spare = RendererSlot.acquire(in: slots, count: SchemaReviewRenderer.slotCount)
        XCTAssertNotNil(spare, "One renderer holds one slot")
        spare?.release()

        // The idle timer runs on the renderer's own queue; the long bound only matters on failure.
        let deadline = Date().addingTimeInterval(30)
        while renderer.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(renderer.isRunning, "An idle renderer stops")
        let freed = (0..<SchemaReviewRenderer.slotCount).compactMap { _ in RendererSlot.acquire(in: slots, count: SchemaReviewRenderer.slotCount) }
        XCTAssertEqual(freed.count, SchemaReviewRenderer.slotCount, "A stopped renderer frees its slot")
        freed.forEach { $0.release() }

        XCTAssertEqual(SchemaReviewAppTools.frame(arguments: arguments, workingDirectory: directory.path, renderer: renderer)["isError"] as? Bool, false)
        let dispatcher = LocalMCPToolDispatcher(transport: UnusedTransport(), renderer: renderer, openDocuments: { _ in })
        dispatcher.clientDisconnected(clientID: "client")
        XCTAssertFalse(renderer.isRunning, "The renderer stops with the client that started it")
    }

    func testRendererRunsFromAReusedCloneOfTheAppExecutable() throws {
        let source = directory.appendingPathComponent("SQLiteGraphStudio")
        try Data("#!/bin/sh\n".utf8).write(to: source)
        let clones = directory.appendingPathComponent("clones", isDirectory: true)
        let clone = try SchemaReviewRenderer.clone(of: source, in: clones)
        XCTAssertEqual(clone.lastPathComponent, SchemaReviewRenderer.rendererName)
        XCTAssertNotEqual(try inode(clone), try inode(source), "A separate file keeps macOS from taking the renderer for the app")
        XCTAssertEqual(try SchemaReviewRenderer.clone(of: source, in: clones), clone)

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        let rebuilt = try SchemaReviewRenderer.clone(of: source, in: clones)
        XCTAssertNotEqual(rebuilt, clone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path), "Clones of earlier builds are removed")
    }

    func testOpensTheReviewInGraphStudioBesideItsOriginalSchema() throws {
        try write(review(), to: "change.sgreview")
        var opened: [[URL]] = []
        let dispatcher = LocalMCPToolDispatcher(transport: UnusedTransport(), renderer: renderer(executable: nil),
                                                openDocuments: { opened.append($0) })
        let call = MCPToolCall(name: SchemaReviewAppTools.openToolName, arguments: ["path": "change.sgreview"], contextID: nil,
                               clientID: "client", clientName: nil, clientVersion: nil, workingDirectory: directory.path)
        XCTAssertEqual(dispatcher.dispatch(call)["isError"] as? Bool, false)
        let urls = try XCTUnwrap(opened.first)
        XCTAssertEqual(urls.count, 2)
        defer { try? FileManager.default.removeItem(at: urls[1].deletingLastPathComponent()) }
        XCTAssertEqual(urls[0].path, directory.appendingPathComponent("change.sgreview").standardizedFileURL.path,
                       "The review comes first, so Graph Studio keeps it as the active tab")

        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: urls[1])) as? [String: Any])
        XCTAssertEqual(original["title"] as? String, "Original · Sessions")
        XCTAssertEqual(original["headRef"] as? String, "base")
        XCTAssertNil(original["author"], "Without an author the original can't replace the review's tab")
        XCTAssertNil(original["proposal"])
        XCTAssertEqual(original["after"] as? NSDictionary, original["before"] as? NSDictionary)
        let shown = SchemaReviewInlineView.detail(path: urls[1].path, workingDirectory: "/")
        XCTAssertEqual(shown["isError"] as? Bool, false)
        XCTAssertEqual(((shown["structuredContent"] as? [String: Any])?["tables"] as? [Any])?.count, 0, "Nothing changes in the original")

        XCTAssertEqual(dispatcher.dispatch(call)["isError"] as? Bool, false)
        XCTAssertEqual(opened.last, urls, "Opening again reuses the same files, so Graph Studio replaces both tabs")
        XCTAssertEqual(errorCode(dispatcher.dispatch(MCPToolCall(
            name: SchemaReviewAppTools.openToolName, arguments: ["path": "missing.sgreview"], contextID: nil,
            clientID: "client", clientName: nil, clientVersion: nil, workingDirectory: directory.path))), "OBJECT_NOT_FOUND")
        XCTAssertEqual(opened.count, 2)
    }

    func testDefinitionLabelsHideContentHashes() {
        XCTAssertEqual(SchemaReviewInlineView.definitionLabel("index:users_email"), "Index users_email")
        XCTAssertEqual(SchemaReviewInlineView.definitionLabel("constraint:" + String(repeating: "ab", count: 32)), "Constraint")
        XCTAssertEqual(SchemaReviewInlineView.definitionLabel("definition"), "Table definition")
        XCTAssertEqual(SchemaReviewInlineView.definitionLabel("option:fillfactor"), "Option fillfactor")
    }

    // MARK: Fixtures

    private func column(_ name: String, type: String = "TEXT", notNull: Bool = false, defaultSQL: String? = nil, pk: Int = 0) -> [String: Any] {
        var value: [String: Any] = ["name": name, "type": type, "notNull": notNull, "primaryKeyOrdinal": pk, "generated": 0, "identity": ""]
        if let defaultSQL { value["defaultSQL"] = defaultSQL }
        return value
    }

    private func table(_ id: String, columns: [[String: Any]], metadata: [String: String] = [:]) -> [String: Any] {
        ["id": id, "name": id, "kind": "table", "columns": columns, "metadata": metadata]
    }

    private func relation(_ id: String, _ source: String, _ column: String, _ target: String) -> [String: Any] {
        ["id": id, "source": source, "target": target, "sourceColumns": [column], "targetColumns": ["id"],
         "definition": "FOREIGN KEY (\(column)) REFERENCES \(target)(id)"]
    }

    /// `users` gains `active`, loses `nickname`, tightens `email`, and its index becomes unique;
    /// `sessions` replaces `legacy_tokens`; `teams` is related context; `projects` is unrelated.
    private func review() -> [String: Any] {
        let teams = table("teams", columns: [column("id", type: "INTEGER", pk: 1), column("name")])
        let projects = table("projects", columns: [column("id", type: "INTEGER", pk: 1)])
        let usersBefore = table("users", columns: [
            column("id", type: "INTEGER", pk: 1), column("team_id", type: "INTEGER"), column("email"), column("nickname"),
        ], metadata: ["index:users_email": "CREATE INDEX users_email ON users(email)"])
        let usersAfter = table("users", columns: [
            column("id", type: "INTEGER", pk: 1), column("team_id", type: "INTEGER"),
            column("email", notNull: true, defaultSQL: "''"), column("active", type: "INTEGER"),
        ], metadata: ["index:users_email": "CREATE UNIQUE INDEX users_email ON users(email)"])
        let tokens = table("legacy_tokens", columns: [column("id", type: "INTEGER", pk: 1), column("user_id", type: "INTEGER")])
        let sessions = table("sessions", columns: [column("id", type: "INTEGER", pk: 1), column("user_id", type: "INTEGER")])
        return [
            "version": 1, "title": "Sessions", "baseRef": "base", "headRef": "head", "notes": ["Fixture."],
            "author": ["tool": "Claude Code", "session": "Review session"],
            "before": ["version": 1, "engine": "sqlite", "tables": [teams, projects, usersBefore, tokens],
                       "relations": [relation("fk_team", "users", "team_id", "teams"), relation("fk_tokens", "legacy_tokens", "user_id", "users")]],
            "after": ["version": 1, "engine": "sqlite", "tables": [teams, projects, usersAfter, sessions],
                      "relations": [relation("fk_team", "users", "team_id", "teams"), relation("fk_sessions", "sessions", "user_id", "users")]],
        ]
    }

    private func write(_ document: [String: Any], to name: String) throws {
        try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent(name))
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

    private func renderer(executable: URL?, slots: URL? = nil, idleTimeout: TimeInterval = 60) -> SchemaReviewRenderer {
        SchemaReviewRenderer(executableProvider: { executable },
                             slotDirectory: slots ?? directory.appendingPathComponent("slots", isDirectory: true),
                             cloneDirectory: directory.appendingPathComponent("clones", isDirectory: true),
                             idleTimeout: idleTimeout)
    }

    /// Answers every request like Graph Studio's renderer, without drawing anything.
    private func fakeRenderer() throws -> URL {
        let url = directory.appendingPathComponent("fake-renderer")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          printf '{"id":%s,"ok":true,"image":"AAAA","mimeType":"image/jpeg","width":640,"height":400,"sets":2,"setTables":[["users"],["teams"]],"set":1,"selection":["teams"]}\\n' "$id"
        done

        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func inode(_ url: URL) throws -> UInt64 {
        ((try FileManager.default.attributesOfItem(atPath: url.path))[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        XCTAssertEqual(result["isError"] as? Bool, true)
        return ((result["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
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

/// Counts any attempt to reach the app; the inline review must never make one.
private final class UnusedTransport: MCPBridgeTransport {
    private(set) var calls = 0

    func status(clientID: String) -> [String: Any] { calls += 1; return [:] }
    func launch(clientID: String, timeoutMilliseconds: Int, foreground: Bool) -> [String: Any] { calls += 1; return [:] }
    func call(_ call: MCPToolCall, contextID: String?) -> [String: Any] { calls += 1; return [:] }
}
