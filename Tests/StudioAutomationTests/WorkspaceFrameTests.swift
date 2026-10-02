import AppKit
import Foundation
@testable import StudioCore
import SwiftUI
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct WorkspaceFrameTests {
    @Test @MainActor
    func explanationsRequireInlineAcknowledgementAndStayEmbeddedAfterRelease() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inline-playback-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = AppSession()
        let tabs = WorkspaceTabController(initialSession: initial)
        let coordinator = StudioAutomationCoordinator(workspaces: tabs, inlineViewerLifetime: .seconds(12))
        let connected = payload(await call(coordinator, "studio_connect_context", ["client_task_id": "inline-playback"]))
        let context = try #require(connected["context_id"] as? String)
        let opened = payload(await call(coordinator, "studio_open_source", ["context_id": context,
            "source_path": file.path, "request_id": UUID().uuidString]))
        let workspace = try #require(opened["workspace_id"] as? String)
        let uuid = try #require(UUID(uuidString: workspace))
        tabs.activate(uuid)
        let started = payload(await call(coordinator, "studio_start_presentation", ["context_id": context,
            "workspace_id": workspace, "narration_mode": "enabled", "activation_intent": "background",
            "request_id": UUID().uuidString, "points": [
                ["point_id": "author", "caption": "Each post belongs to an author.", "timing": ["advance": "automatic", "minimum_visible_ms": 0],
                 "actions": [["type": "show_tables", "table_ids": ["posts", "authors"], "mode": "replace"]]],
                ["point_id": "editor", "caption": "An editor is optional.", "timing": ["advance": "automatic", "minimum_visible_ms": 0]]
            ]]))
        let presentation = try #require(started["presentation_id"] as? String)
        #expect(started["navigation_mode"] as? String == "steps")
        #expect(started["presentation_surface"] as? String == "embedded")
        #expect(started["narration_enabled"] as? Bool == false)
        #expect(started["current_point_has_audio"] as? Bool == false,
                "Legacy narration settings must not start local speech")
        let inspection: [String: Any] = ["context_id": context, "workspace_id": workspace, "presentation_id": presentation]
        // The embedded renderer must not depend on a desktop view being mounted.
        let hosting = NSView()
        var route: [String: Any] = ["context_id": context, "workspace_id": workspace, "width": 700,
                                    "viewer_id": "inline-playback-viewer", "render_surface": "graph"]
        var frame = try await readyFrame(coordinator, hosting: hosting, arguments: route)
        #expect(frame["window_visible"] as? Bool == false, "This exercises rendering without an exposed native window")
        var pointVisible = payload(await call(coordinator, "studio_get_presentation", inspection))["point_visible"] as? Bool
        #expect(pointVisible == false,
                "Fetching a frame alone must not start narration or count viewing time")
        route["source_id"] = frame["source_id"]
        route["source_revision"] = frame["source_revision"]
        route["after_frame_revision"] = "unserved-frame"
        route["rendered_point_id"] = "author"
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        pointVisible = payload(await call(coordinator, "studio_get_presentation", inspection))["point_visible"] as? Bool
        #expect(pointVisible == false)
        route["after_frame_revision"] = frame["frame_revision"]
        route["rendered_point_id"] = "editor"
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        pointVisible = payload(await call(coordinator, "studio_get_presentation", inspection))["point_visible"] as? Bool
        #expect(pointVisible == false, "A different point cannot acknowledge this frame")
        route["after_frame_revision"] = frame["frame_revision"]
        route["rendered_point_id"] = "author"
        route["inline_view_state"] = "acknowledged"
        let receipt = payload(await call(coordinator, "studio_workspace_frame", route))
        pointVisible = payload(await call(coordinator, "studio_get_presentation", inspection))["point_visible"] as? Bool
        #expect(pointVisible == true)
        #expect(receipt["frame_acknowledged"] as? Bool == true)
        #expect(receipt["image"] == nil, "Confirming a decoded frame must not encode and send another full image")
        #expect((receipt["presentation"] as? [String: Any])?["visual_state"] as? String == "rendered_inline")
        #expect((receipt["presentation"] as? [String: Any])?["navigation_mode"] as? String == "steps")
        try await Task.sleep(for: .milliseconds(50))
        #expect(payload(await call(coordinator, "studio_get_presentation", inspection))["current_caption"] as? String == "Each post belongs to an author.",
                "An embedded view must wait even when the authored point is automatic with no hold")
        route.removeValue(forKey: "inline_view_state")
        route["maximum_frame_age_ms"] = 5_000
        let reused = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(reused["image_cached"] as? Bool == true)
        #expect(reused["image"] == nil)
        #expect(reused["frame_revision"] as? String == route["after_frame_revision"] as? String)
        let control: [String: Any] = ["context_id": context, "workspace_id": workspace, "presentation_id": presentation,
                                      "control": "next", "request_id": UUID().uuidString]
        _ = await call(coordinator, "studio_control_presentation", control)
        frame = try await readyFrame(coordinator, hosting: hosting, arguments: route)
        pointVisible = payload(await call(coordinator, "studio_get_presentation", inspection))["point_visible"] as? Bool
        #expect(pointVisible == false,
                "The previous point's acknowledgement must not make the next point visible")
        route["after_frame_revision"] = frame["frame_revision"]
        route["rendered_point_id"] = "editor"
        _ = await call(coordinator, "studio_workspace_frame", route)
        pointVisible = payload(await call(coordinator, "studio_get_presentation", inspection))["point_visible"] as? Bool
        #expect(pointVisible == true)
        route["inline_view_state"] = "released"
        let stranger = await call(coordinator, "studio_workspace_frame", route, client: "another-client")
        #expect(stranger["isError"] as? Bool == true)
        #expect(payload(await call(coordinator, "studio_get_presentation", inspection))["status"] as? String == "waiting_for_next")
        // Mount the native view as well. The packaged smoke checks real desktop exposure;
        // the Swift test host is not guaranteed a foreground WindowServer connection.
        let nativeHost = NSHostingView(rootView: StudioRootView(session: initial, workspaceTabs: tabs,
                                                               frameCaptures: coordinator.workspaceFrameCaptures))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1024, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = nativeHost
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        _ = await call(coordinator, "studio_workspace_frame", route)
        #expect(payload(await call(coordinator, "studio_get_presentation", inspection))["status"] as? String == "paused")
        route.removeValue(forKey: "inline_view_state")
        let afterRelease = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(window.isVisible)
        #expect((afterRelease["presentation"] as? [String: Any])?["status"] as? String == "paused")
        var goBack = inspection
        goBack["control"] = "back"; goBack["request_id"] = UUID().uuidString
        _ = await call(coordinator, "studio_control_presentation", goBack)
        frame = try await readyFrame(coordinator, hosting: nativeHost, arguments: route)
        #expect(window.isVisible)
        #expect((frame["presentation"] as? [String: Any])?["point_visible"] as? Bool == false,
                "Mounting the native graph cannot make the embedded point visible")
        try await Task.sleep(for: .milliseconds(12200))
        var finalState = payload(await call(coordinator, "studio_get_presentation", inspection))
        #expect(finalState["status"] as? String == "paused")
        #expect(finalState["current_point_id"] as? String == "author")
        #expect(finalState["presentation_surface"] as? String == "embedded")
        _ = await call(coordinator, "studio_workspace_frame", route)
        coordinator.disconnectClient("native-frame-client")
        let token = try #require(connected["resume_token"] as? String)
        let reconnected = await call(coordinator, "studio_connect_context", ["client_task_id": "inline-playback",
            "resume_context_id": context, "resume_token": token], client: "resumed-client")
        #expect(reconnected["isError"] as? Bool == false)
        finalState = payload(await call(coordinator, "studio_get_presentation", inspection, client: "resumed-client"))
        #expect(finalState["status"] as? String == "paused")
        #expect(finalState["navigation_mode"] as? String == "steps")
        #expect(finalState["point_visible"] as? Bool == false)
        #expect(finalState["narration_enabled"] as? Bool == false)
        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor private func readyFrame(_ coordinator: StudioAutomationCoordinator, hosting: NSView,
                                      arguments: [String: Any]) async throws -> [String: Any] {
        var frame: [String: Any] = [:]
        for _ in 0..<100 {
            hosting.layoutSubtreeIfNeeded()
            let result = await call(coordinator, "studio_workspace_frame", arguments)
            frame = payload(result)
            if let error = frame["error"] as? [String: Any], error["code"] as? String != "VIEW_NOT_RENDERED" {
                Issue.record("Workspace frame rejected: \(error["code"] ?? "unknown") \(error["message"] ?? "")")
                throw FrameTimeout()
            }
            if (frame["presentation"] as? [String: Any])?["view_ready"] as? Bool == true { return frame }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Embedded point did not become ready: \(frame["presentation"] ?? "No presentation")")
        throw FrameTimeout()
    }
    private struct FrameTimeout: Error {}

    @Test @MainActor
    func savedExplanationsShowOnlyReferencedCapturedDataThroughEmbeddedMCP() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-capture-\(UUID()).sgexplanation")
        defer { try? FileManager.default.removeItem(at: file) }
        let columns = (0..<21).map { index in
            SchemaReviewSnapshot.Column(name: index == 0 ? "id" : "field_\(index)",
                type: index == 0 ? "INTEGER" : "TEXT", notNull: index == 0,
                defaultSQL: nil, primaryKeyOrdinal: index == 0 ? 1 : 0, generated: 0, identity: "")
        }
        let capturedColumns = columns.map { HistoricalExplanationArtifact.CapturedColumn(name: $0.name, type: $0.type) }
        let schema = SchemaReviewSnapshot(engine: "sqlite", tables: [
            .init(id: "items", schema: nil, name: "items", kind: "table", columns: columns, metadata: [:])
        ], relations: [])
        let rows = (0..<12).map { index in
            HistoricalExplanationArtifact.CapturedRow(ordinal: index + 4, values: [
                .init(type: "integer", value: String(index + 42)),
                .init(type: "text", value: String(repeating: "x", count: 400)),
                .init(type: "redacted", value: nil), .init(type: "null", value: nil)
            ] + (4..<21).map { .init(type: "text", value: "Captured field \($0)") })
        }
        let artifact = HistoricalExplanationArtifact(title: "Captured items", engine: "sqlite",
            sourceIdentityHash: String(repeating: "a", count: 64), sourceRevisionHash: String(repeating: "b", count: 64),
            schema: schema, points: [
                .init(id: "table", caption: "Inspect the captured item.", narration: "Archived spoken words.",
                      minimumVisibleMilliseconds: 0, extraHoldMilliseconds: 0, advance: "automatic",
                      actions: [.object(["type": .string("open_table"), "table_id": .string("items")])]),
                .init(id: "query", caption: "Inspect the captured query evidence.", narration: nil,
                      minimumVisibleMilliseconds: 0, extraHoldMilliseconds: 0, advance: "automatic",
                      actions: [.object(["type": .string("set_layout"), "right_pane": .string("query")])],
                      evidence: [.init(kind: "query_result", objectID: "saved-query", resultID: "saved-query")]),
                .init(id: "graph", caption: "Return to the captured schema.", narration: nil,
                      minimumVisibleMilliseconds: 0, extraHoldMilliseconds: 0, advance: "automatic", actions: []),
            ], queryResults: [
                .init(resultID: "unreferenced", columns: [capturedColumns[0]], rows: [
                    .init(ordinal: 0, values: [.init(type: "integer", value: "123")])
                ], displayedOffset: 0, omittedRows: 0, sourceWasTruncated: false),
                .init(resultID: "saved-query", columns: [capturedColumns[0]], rows: [
                    .init(ordinal: 11, values: [.init(type: "integer", value: "99")])
                ], displayedOffset: 11, omittedRows: 2, sourceWasTruncated: true),
            ], tablePages: [.init(tableID: "items", columns: capturedColumns, rows: rows, displayedOffset: 4, omittedRows: 0)])
        try HistoricalExplanationStore.write(artifact, to: file)
        let originalBytes = try Data(contentsOf: file)
        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let context = try #require(payload(await call(coordinator, "studio_connect_context", ["client_task_id": "saved-inline"]))["context_id"] as? String)
        let opened = payload(await call(coordinator, "studio_open_explanation", ["context_id": context,
            "path": file.path, "start_mode": "replay", "request_id": UUID().uuidString]))
        let workspace = try #require(opened["workspace_id"] as? String)
        let presentation = try #require((opened["presentation"] as? [String: Any])?["presentation_id"] as? String)
        #expect(opened["live_queries_executed"] as? Bool == false)
        #expect(tabs.activeTab?.session.databaseURL == nil && tabs.activeTab?.session.databaseTarget == nil)
        var route: [String: Any] = ["context_id": context, "workspace_id": workspace, "viewer_id": "saved-inline",
                                   "render_surface": "graph", "width": 700, "height": 440]
        var frame = try await readyFrame(coordinator, hosting: NSView(), arguments: route)
        let tableView = try #require(frame["data_view"] as? [String: Any])
        #expect(tableView["kind"] as? String == "table" && tableView["historical"] as? Bool == true)
        #expect(tableView["offset"] as? Int == 4)
        #expect((tableView["columns"] as? [[String: Any]])?.count == 20)
        #expect(tableView["omitted_column_count"] as? Int == 1 && tableView["has_more"] as? Bool == true)
        let displayedRows = try #require(tableView["rows"] as? [[String: Any]])
        #expect(displayedRows.count == 10)
        let cells = try #require(displayedRows.first?["values"] as? [[String: Any]])
        #expect(cells.count == 20 && cells[0]["value"] as? String == "42")
        #expect((cells[1]["value"] as? String)?.count == 256 && cells[1]["truncated"] as? Bool == true)
        #expect(cells[2]["type"] as? String == "redacted" && cells[3]["type"] as? String == "null")
        route["source_id"] = frame["source_id"]; route["source_revision"] = frame["source_revision"]
        route["after_frame_revision"] = frame["frame_revision"]; route["rendered_point_id"] = "table"
        route["inline_view_state"] = "acknowledged"
        let acknowledged = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(acknowledged["frame_acknowledged"] as? Bool == true)
        try await Task.sleep(for: .milliseconds(50))
        let historicalSource = try #require(frame["source_id"] as? String)
        let historicalRevision = try #require(frame["source_revision"] as? String)
        let inspection: [String: Any] = ["context_id": context, "workspace_id": workspace, "presentation_id": presentation,
                                         "source_id": historicalSource, "source_revision": historicalRevision]
        #expect(historicalSource.hasPrefix("historical:"))
        #expect(code(await call(coordinator, "studio_fetch_rows", ["context_id": context, "workspace_id": workspace,
            "table_id": "items"])) == "SOURCE_REQUIRED", "Visual access must not grant a live read from a saved artifact")
        let selected = await call(coordinator, "studio_update_workspace", ["context_id": context, "workspace_id": workspace,
            "source_id": historicalSource, "source_revision": historicalRevision,
            "changes": ["activate": true], "request_id": UUID().uuidString])
        #expect(selected["isError"] as? Bool == false)
        let state = payload(await call(coordinator, "studio_get_presentation", inspection))
        #expect(state["current_point_id"] as? String == "table" && state["narration_enabled"] as? Bool == false)
        route.removeValue(forKey: "inline_view_state")
        var control = inspection; control["control"] = "next"; control["request_id"] = UUID().uuidString
        _ = await call(coordinator, "studio_control_presentation", control)
        frame = try await readyFrame(coordinator, hosting: NSView(), arguments: route)
        let queryView = try #require(frame["data_view"] as? [String: Any])
        #expect(queryView["kind"] as? String == "query" && queryView["historical"] as? Bool == true)
        #expect(queryView["offset"] as? Int == 11 && queryView["source_truncated"] as? Bool == true)
        let queryRows = try #require(queryView["rows"] as? [[String: Any]])
        #expect(queryRows.count == 1 && (queryRows[0]["values"] as? [[String: Any]])?.first?["value"] as? String == "99",
                "A saved query step must never display unrelated captured results")
        control["request_id"] = UUID().uuidString
        _ = await call(coordinator, "studio_control_presentation", control)
        frame = try await readyFrame(coordinator, hosting: NSView(), arguments: route)
        #expect(frame["data_view"] is NSNull, "Captured rows close when the next point asks only for the graph")
        #expect((frame["presentation"] as? [String: Any])?["point_number"] as? Int == 3)
        #expect(tabs.makeRestorationSnapshot().tabs.count == 1)
        #expect(try Data(contentsOf: file) == originalBytes)
        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func embeddedGraphShowsRowsOnlyForThePointThatNeedsThemAndInspectsItsOwnViewport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-graph-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let context = try #require(payload(await call(coordinator, "studio_connect_context", ["client_task_id": "embedded-graph"]))["context_id"] as? String)
        let workspace = try #require(payload(await call(coordinator, "studio_open_source", ["context_id": context,
            "source_path": file.path, "request_id": UUID().uuidString]))["workspace_id"] as? String)
        tabs.activate(try #require(UUID(uuidString: workspace)))
        _ = await call(coordinator, "studio_open_table", ["context_id": context, "workspace_id": workspace,
            "table_id": "posts", "request_id": UUID().uuidString])
        let originalBytes = try Data(contentsOf: file)
        let sourceSession = try #require(tabs.activeTab?.session)
        var route: [String: Any] = ["context_id": context, "workspace_id": workspace, "viewer_id": "graph-only",
                                    "render_surface": "graph", "width": 700, "height": 440]
        var frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(frame["render_surface"] as? String == "graph")
        #expect(frame["data_view"] is NSNull, "An open desktop grid must not make the embedded graph show rows")
        let image = try #require((frame["image"] as? String).flatMap { Data(base64Encoded: $0) })
        let bitmap = try #require(NSBitmapImageRep(data: image))
        #expect(bitmap.pixelsWide == 1400 && bitmap.pixelsHigh == 880)
        #expect(image.count > 2_000 && image.count <= 2_000_000,
                "Retina native graph frames must stay inside the graph image transport budget")
        var acknowledgement = route
        acknowledgement["after_frame_revision"] = frame["frame_revision"]
        acknowledgement["inline_view_state"] = "acknowledged"
        sourceSession.showClusterHalos.toggle()
        #expect(payload(await call(coordinator, "studio_workspace_frame", acknowledgement))["frame_acknowledged"] as? Bool == false,
                "A frame drawn before a graph style change cannot confirm visibility")
        _ = await call(coordinator, "studio_set_camera", ["context_id": context, "workspace_id": workspace,
            "zoom": 0.6, "pan_x": 20, "pan_y": 10, "transition_ms": 0, "request_id": UUID().uuidString])
        // A desktop graph may consume the transient command before the card polls.
        if let command = sourceSession.automationViewportCommand { sourceSession.clearAutomationViewportCommand(id: command.id) }
        let cameraFrame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect((cameraFrame["graph"] as? [String: Any])?["zoom"] as? Double == 0.6)
        #expect((cameraFrame["graph"] as? [String: Any])?["pan_x"] as? Double == 20)
        #expect((cameraFrame["graph"] as? [String: Any])?["pan_y"] as? Double == 10)
        let started = payload(await call(coordinator, "studio_start_presentation", ["context_id": context,
            "workspace_id": workspace, "narration_mode": "disabled", "activation_intent": "background",
            "request_id": UUID().uuidString, "points": [
                ["point_id": "keys", "caption": "Posts link to authors.", "timing": ["advance": "manual", "minimum_visible_ms": 0],
                 "actions": [["type": "show_tables", "table_ids": ["authors", "posts"], "mode": "replace"],
                             ["type": "focus_keys", "table_id": "posts", "source_column": "author_id"]]],
                ["point_id": "rows", "caption": "Inspect the optional editor.", "timing": ["advance": "manual", "minimum_visible_ms": 0],
                 "actions": [["type": "show_tables", "table_ids": ["authors", "posts"], "mode": "replace"],
                             ["type": "expand_tables", "table_ids": ["posts"]],
                             ["type": "open_table", "table_id": "posts"]]],
                ["point_id": "graph-again", "caption": "Return to the graph.", "timing": ["advance": "manual", "minimum_visible_ms": 0]]
            ]]))
        let presentation = try #require(started["presentation_id"] as? String)
        frame = try await readyFrame(coordinator, hosting: NSView(), arguments: route)
        #expect(frame["data_view"] is NSNull)
        let focusedRoot = try #require(((frame["graph"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first { $0["table_id"] as? String == "posts" })
        #expect((focusedRoot["width"] as? Double ?? 0) >= 440 * 0.9 - 1,
                "Embedded hit regions must cover the readable focus card, even below normal detail zoom")
        route["after_frame_revision"] = frame["frame_revision"]
        route["rendered_point_id"] = "keys"
        route["inline_view_state"] = "acknowledged"
        _ = await call(coordinator, "studio_workspace_frame", route)
        route.removeValue(forKey: "inline_view_state")
        route["maximum_frame_age_ms"] = 5000
        route["graph_actions"] = [["type": "transform", "tx": 40], ["type": "invalid"]]
        #expect(code(await call(coordinator, "studio_workspace_frame", route)) == "INVALID_ARGUMENT")
        route.removeValue(forKey: "graph_actions")
        let unchanged = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(unchanged["frame_revision"] as? String == frame["frame_revision"] as? String,
                "An invalid batch must not partially move the graph")
        #expect((unchanged["presentation"] as? [String: Any])?["status"] as? String == "waiting_for_next")
        route["after_frame_revision"] = unchanged["frame_revision"]
        let nativePan = sourceSession.graphPan
        route["graph_actions"] = [["type": "transform", "scale": 1, "tx": 40, "ty": 0]]
        let inspected = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(inspected["frame_revision"] as? String != frame["frame_revision"] as? String)
        #expect((inspected["presentation"] as? [String: Any])?["status"] as? String == "paused")
        #expect(sourceSession.graphPan == nativePan, "Embedded gestures must not move the desktop viewport")
        route["after_frame_revision"] = inspected["frame_revision"]
        route["graph_actions"] = [["type": "select", "table_id": "posts"]]
        let selectedFrame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect((selectedFrame["graph"] as? [String: Any])?["selection"] as? [String] == ["posts"])
        route["after_frame_revision"] = selectedFrame["frame_revision"]
        route["graph_actions"] = [["type": "expand", "table_id": "posts"]]
        let expandedFrame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect((expandedFrame["graph"] as? [String: Any])?["expanded_table_ids"] as? [String] == ["posts"],
                "Inspecting a point must keep later gestures usable")
        route.removeValue(forKey: "graph_actions")
        var control: [String: Any] = ["context_id": context, "workspace_id": workspace, "presentation_id": presentation,
                                      "control": "next", "request_id": UUID().uuidString]
        _ = await call(coordinator, "studio_control_presentation", control)
        frame = try await readyFrame(coordinator, hosting: NSView(), arguments: route)
        let data = try #require(frame["data_view"] as? [String: Any])
        #expect((frame["graph"] as? [String: Any])?["expanded_table_ids"] as? [String] == ["posts"],
                "Leaving relation focus must preserve the next point's explicit expansion")
        #expect(data["table_id"] as? String == "posts")
        let rows = try #require(data["rows"] as? [[String: Any]])
        #expect(rows.count == 10)
        let postFive = try #require(rows.first { ($0["values"] as? [[String: Any]])?.first?["value"] as? String == "5" })
        let cells = try #require(postFive["values"] as? [[String: Any]])
        #expect(cells[2]["type"] as? String == "null", "The fixture's fifth post has no editor")
        control["request_id"] = UUID().uuidString
        _ = await call(coordinator, "studio_control_presentation", control)
        frame = try await readyFrame(coordinator, hosting: NSView(), arguments: route)
        #expect(frame["data_view"] is NSNull, "Data from the previous point must close on the next graph-only point")
        let finalBytes = try Data(contentsOf: file)
        #expect(finalBytes == originalBytes)
        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func embeddedNodesRemainInteractiveAndReturnFromTheirFullModelContext() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("node-inspection-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let context = try #require(payload(await call(coordinator, "studio_connect_context", ["client_task_id": "node-inspection"]))["context_id"] as? String)
        let workspace = try #require(payload(await call(coordinator, "studio_open_source", ["context_id": context,
            "source_path": file.path, "request_id": UUID().uuidString]))["workspace_id"] as? String)
        tabs.activate(try #require(UUID(uuidString: workspace)))
        let source = try #require(tabs.activeTab?.session)
        source.restoreGraphFilterWithoutCounting(GraphTableFilter(maximumFields: 0))
        _ = await call(coordinator, "studio_show_tables", ["context_id": context, "workspace_id": workspace,
            "operation": "all", "table_ids": [], "highlight_table_ids": ["authors", "posts"], "request_id": UUID().uuidString])
        #expect(source.graphContextTableIDs == ["authors", "posts"])
        #expect(source.graphVisibleTableIDs.count > 2)
        #expect(source.graphVisibleTableIDs.count == source.graph.nodes.count,
                "An explicit context map includes subjects excluded by saved detail filters")
        let invalidContext = await call(coordinator, "studio_show_tables", ["context_id": context, "workspace_id": workspace,
            "table_ids": ["posts"], "highlight_table_ids": ["missing"], "request_id": UUID().uuidString])
        #expect(code(invalidContext) == "INVALID_ARGUMENT")
        #expect(source.graphContextTableIDs == ["authors", "posts"], "Invalid context requests must leave the view intact")
        source.restoreGraphFilterWithoutCounting(GraphTableFilter())
        _ = await call(coordinator, "studio_show_tables", ["context_id": context, "workspace_id": workspace,
            "table_ids": ["authors", "posts"], "request_id": UUID().uuidString])
        #expect(source.graphContextTableIDs.isEmpty, "Returning to a detail scope clears the context highlight")
        let sourceScope = source.graphVisibleTableIDs, nativePan = source.graphPan
        var route: [String: Any] = ["context_id": context, "workspace_id": workspace, "viewer_id": "node-inspection",
                                   "render_surface": "graph", "width": 700, "height": 440]
        var frame = payload(await call(coordinator, "studio_workspace_frame", route))
        func graph(_ f: [String: Any]) -> [String: Any] { f["graph"] as? [String: Any] ?? [:] }
        let nodes = try #require(graph(frame)["nodes"] as? [[String: Any]])
        #expect(Set(nodes.compactMap { $0["table_id"] as? String }) == ["authors", "posts"])
        let post = try #require(nodes.first { $0["table_id"] as? String == "posts" })
        #expect((post["width"] as? Double ?? 0) > 20 && (post["height"] as? Double ?? 0) > 10)
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "select", "table_id": "posts"]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(graph(frame)["selection"] as? [String] == ["posts"])
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "expand", "table_id": "posts"]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(graph(frame)["expanded_table_ids"] as? [String] == ["posts"], "An earlier selection must not lock out expansion")
        let beforeZoom = try #require(graph(frame)["zoom"] as? Double)
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "transform", "scale": 1.5, "tx": -175, "ty": -110]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect((graph(frame)["zoom"] as? Double ?? 0) > beforeZoom)
        let zoomImage = try #require((frame["image"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(NSBitmapImageRep(data: zoomImage)?.pixelsWide == 1400, "Zoom must redraw at Retina resolution, not enlarge an old frame")
        let detailZoom = graph(frame)["zoom"] as? Double
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "context"]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(graph(frame)["context_mode"] as? Bool == true)
        #expect(Set(graph(frame)["highlight_table_ids"] as? [String] ?? []) == ["authors", "posts"])
        #expect((frame["visible_table_ids"] as? [String] ?? []).count > 2)
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "transform", "tx": 31, "ty": 17]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        let contextZoom = graph(frame)["zoom"] as? Double
        let contextPanX = graph(frame)["pan_x"] as? Double, contextPanY = graph(frame)["pan_y"] as? Double
        // A desktop camera/selection or completed table-load update is not a new
        // agent instruction and must not erase inspection in the embedded card.
        source.graphPan.width += 30
        source.setGraphSelection(["authors"])
        source.expandedGraphNodeIDs = ["authors"]
        source.restoreGraphFilterWithoutCounting(GraphTableFilter(maximumFields: 0))
        route["after_frame_revision"] = frame["frame_revision"]
        route.removeValue(forKey: "graph_actions")
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(graph(frame)["context_mode"] as? Bool == true)
        #expect(graph(frame)["zoom"] as? Double == contextZoom)
        #expect(graph(frame)["pan_x"] as? Double == contextPanX && graph(frame)["pan_y"] as? Double == contextPanY)
        #expect((frame["visible_table_ids"] as? [String] ?? []).count == source.graph.nodes.count,
                "Full context must include highlighted tables hidden by a native detail filter")
        #expect(Set(graph(frame)["highlight_table_ids"] as? [String] ?? []) == ["authors", "posts"])
        source.restoreGraphFilterWithoutCounting(GraphTableFilter())
        source.graphPan = nativePan
        route["after_frame_revision"] = frame["frame_revision"]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "context"]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        #expect(graph(frame)["context_mode"] as? Bool == false)
        #expect(graph(frame)["zoom"] as? Double == detailZoom)
        #expect(graph(frame)["selection"] as? [String] == ["posts"])
        #expect(graph(frame)["expanded_table_ids"] as? [String] == ["posts"])
        #expect(Set(frame["visible_table_ids"] as? [String] ?? []) == ["authors", "posts"])
        #expect(source.graphVisibleTableIDs == sourceScope && source.graphPan == nativePan,
                "Embedded inspection must preserve the source workspace")
        let beforeMoveImage = try #require(frame["image"] as? String)
        route["after_frame_revision"] = frame["frame_revision"]
        route["graph_actions"] = [["type": "move", "table_id": "posts", "x": 350, "y": 30]]
        frame = payload(await call(coordinator, "studio_workspace_frame", route))
        let moved = try #require((graph(frame)["nodes"] as? [[String: Any]])?.first { $0["table_id"] as? String == "posts" })
        #expect(abs((moved["center_x"] as? Double ?? 0) - 350) < 1)
        #expect(abs((moved["center_y"] as? Double ?? 0) - 30) < 1)
        #expect(frame["image"] as? String != beforeMoveImage,
                "Moving a table must update native pixels as well as its hit metadata")
        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func capturesTheRealWorkspaceAndRejectsOtherActiveTabsAndStaleSources() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-inline-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = AppSession()
        let tabs = WorkspaceTabController(initialSession: initial)
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await call(coordinator, "studio_connect_context", ["client_task_id": "native-inline"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await call(coordinator, "studio_open_source", ["context_id": context, "source_path": file.path, "request_id": UUID().uuidString])
        let workspace = try #require(payload(opened)["workspace_id"] as? String)
        let uuid = try #require(UUID(uuidString: workspace))
        tabs.activate(uuid)
        let tableOpened = await call(coordinator, "studio_open_table", ["context_id": context, "workspace_id": workspace,
            "table_id": "posts", "request_id": UUID().uuidString])
        #expect(tableOpened["isError"] as? Bool == false)
        let hosting = NSHostingView(rootView: StudioRootView(session: initial, workspaceTabs: tabs,
                                                             frameCaptures: coordinator.workspaceFrameCaptures))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1024, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        var frame: [String: Any] = [:]
        for _ in 0..<100 {
            hosting.layoutSubtreeIfNeeded()
            frame = await call(coordinator, "studio_workspace_frame", ["context_id": context, "workspace_id": workspace, "width": 700])
            if frame["isError"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(frame["isError"] as? Bool == false)
        let table = try #require(descendants(hosting).compactMap { $0 as? NSTableView }.first)
        let visibleRows = table.rows(in: table.visibleRect)
        #expect(visibleRows.location != NSNotFound && visibleRows.length > 0)
        let visibleCell = try #require(table.view(atColumn: 0, row: visibleRows.location, makeIfNecessary: false))
        let marker = NativeCellMarker(frame: CGRect(x: 8, y: 8, width: 30, height: 24))
        visibleCell.addSubview(marker)
        frame = await call(coordinator, "studio_workspace_frame", ["context_id": context, "workspace_id": workspace, "width": 700])
        let state = payload(frame)
        let image = try #require((state["image"] as? String).flatMap { Data(base64Encoded: $0) })
        let bitmap = try #require(NSBitmapImageRep(data: image))
        #expect(bitmap.pixelsWide == 1400, "A 700-point card must receive two pixels per point for Retina text")
        #expect(bitmap.pixelsHigh < 876, "The 1024×640 content includes a tab bar, which must be cropped out")
        if state["mimeType"] as? String == "image/png" {
            #expect(Array(image.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        } else {
            #expect(state["mimeType"] as? String == "image/jpeg")
            #expect(Array(image.prefix(2)) == [255, 216], "Dense UI scenes may use bounded JPEG; the MIME type must match the actual image")
        }
        #expect(image.count > 2_000 && image.count <= 600_000)
        let markerPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent > 0.7
            }.count
        }
        #expect(markerPixels > 50, "Visible native table cells must appear in the frame, not just the grid headers")
        #expect(state["workspace_id"] as? String == workspace)
        #expect(state["format"] as? String == "sqlite-graph-studio/workspace-view")
        let source = try #require(state["source_id"] as? String)
        let started = await call(coordinator, "studio_start_presentation", ["context_id": context, "workspace_id": workspace,
            "request_id": UUID().uuidString, "narration_mode": "disabled", "activation_intent": "background",
            "points": [["caption": "Authors write posts.", "timing": ["advance": "manual"]]]])
        let presentation = try #require(payload(started)["presentation_id"] as? String)
        let staleControl = await call(coordinator, "studio_control_presentation", ["context_id": context, "workspace_id": workspace,
            "request_id": UUID().uuidString, "presentation_id": presentation, "control": "next",
            "source_id": source, "source_revision": "obsolete"])
        #expect(code(staleControl) == "STALE_SOURCE", "A control from an old inline frame cannot advance a changed source")
        let stale = await call(coordinator, "studio_workspace_frame", ["context_id": context, "workspace_id": workspace,
                                                                       "source_id": source, "source_revision": "obsolete"])
        #expect(code(stale) == "STALE_SOURCE")
        #expect(payload(stale)["image"] == nil)
        let stranger = await call(coordinator, "studio_workspace_frame", ["context_id": context, "workspace_id": workspace], client: "another-client")
        #expect(stranger["isError"] as? Bool == true)
        #expect(payload(stranger)["image"] == nil)
        let another = tabs.createTab()
        tabs.activate(another.id)
        let inactive = await call(coordinator, "studio_workspace_frame", ["context_id": context, "workspace_id": workspace])
        #expect(code(inactive) == "WORKSPACE_NOT_ACTIVE")
        #expect(payload(inactive)["image"] == nil, "A card must never capture the currently active unrelated tab")
        var activate: [String: Any] = ["context_id": context, "workspace_id": workspace,
            "source_id": source, "source_revision": "obsolete", "changes": ["activate": true],
            "request_id": UUID().uuidString]
        let staleActivation = await call(coordinator, "studio_update_workspace", activate)
        #expect(code(staleActivation) == "STALE_SOURCE")
        #expect(tabs.activeTabID == another.id, "An obsolete embedded card must not change the selected workspace")
        activate["source_revision"] = state["source_revision"]
        activate["request_id"] = UUID().uuidString
        let strangerActivation = await call(coordinator, "studio_update_workspace", activate, client: "another-client")
        #expect(strangerActivation["isError"] as? Bool == true)
        #expect(tabs.activeTabID == another.id)
        let selected = await call(coordinator, "studio_update_workspace", activate)
        #expect(selected["isError"] as? Bool == false)
        #expect(tabs.activeTabID == uuid, "A validated app shortcut must select the workspace shown in the card")
        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor private func call(_ coordinator: StudioAutomationCoordinator, _ name: String, _ args: [String: Any], client: String = "native-frame-client") async -> [String: Any] {
        let response = await coordinator.handle(name, arguments: (try? JSONSerialization.data(withJSONObject: args)) ?? Data(),
                                                contextID: args["context_id"] as? String, clientID: client)
        return (try? JSONSerialization.jsonObject(with: response) as? [String: Any]) ?? [:]
    }
    private func payload(_ result: [String: Any]) -> [String: Any] { result["structuredContent"] as? [String: Any] ?? [:] }
    private func code(_ result: [String: Any]) -> String? { (payload(result)["error"] as? [String: Any])?["code"] as? String }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

private final class NativeCellMarker: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.magenta.setFill()
        bounds.fill()
    }
}
