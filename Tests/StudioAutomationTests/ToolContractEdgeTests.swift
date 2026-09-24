import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct ToolContractEdgeTests {
    @Test @MainActor
    func sparseSubsetCompactsAndNarratedPointSelectsItsSubject() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-readable-point-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await invoke(coordinator, "studio_connect_context", ["client_task_id": "readable-point"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await invoke(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], context: context)
        let workspace = try #require(payload(opened)["workspace_id"] as? String)
        let tab = try #require(tabs.tabs.first { $0.id.uuidString == workspace })
        let ids = Array(tab.session.graph.nodes.prefix(3).map(\.id))
        #expect(ids.count == 3)
        for (index, id) in ids.enumerated() {
            tab.session.graphLayout.pin(nodeID: id, at: CGPoint(x: CGFloat(index) * 4_000, y: 0))
        }
        let shown = await invoke(coordinator, "studio_show_tables", [
            "context_id": context, "workspace_id": workspace,
            "request_id": UUID().uuidString, "table_ids": ids,
        ], context: context)
        #expect(shown["isError"] as? Bool == false)
        let positions = ids.map { tab.session.graphLayout.position(for: $0) }
        #expect((positions.map(\.x).max() ?? 0) - (positions.map(\.x).min() ?? 0) == 650)

        let target = ids[1]
        let started = await invoke(coordinator, "studio_start_presentation", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "narration_mode": "enabled", "activation_intent": "foreground",
            "points": [["caption": "This is the table to inspect", "target_table_id": target,
                        "timing": ["advance": "manual"]]],
        ], context: context)
        #expect(started["isError"] as? Bool == false)
        #expect(payload(started)["narration_enabled"] as? Bool == true)
        #expect(payload(started)["current_point_has_audio"] as? Bool == true)
        for _ in 0..<100 where !tab.session.selectedGraphNodeIDs.contains(target) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.session.selectedGraphNodeIDs == [target])

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func graphRelationsExposeUsableRecordIDsAndInvalidViewChangesAreAtomic() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-tool-contract-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await invoke(coordinator, "studio_connect_context", ["client_task_id": "tool-contract-test"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await invoke(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], context: context)
        #expect(opened["isError"] as? Bool == false)
        let workspace = try #require(payload(opened)["workspace_id"] as? String)

        let found = await invoke(coordinator, "studio_find_relations", [
            "context_id": context, "workspace_id": workspace, "table_ids": ["posts"],
        ], context: context)
        #expect(found["isError"] as? Bool == false)
        let edges = try #require(payload(found)["declared_relationships"] as? [[String: Any]])
        let postEdges = edges.filter { $0["source_table_id"] as? String == "posts" }
        #expect(postEdges.count >= 2)
        let sourceTab = try #require(tabs.tabs.first { $0.id.uuidString == workspace })
        let recordIDs = Set(sourceTab.session.records.relationships.map(\.id))
        #expect(postEdges.allSatisfy { edge in
            guard let recordID = edge["record_relation_id"] as? String,
                  let graphID = edge["id"] as? String else { return false }
            return recordID != graphID && recordIDs.contains(recordID)
        })

        let before = await invoke(coordinator, "studio_get_view", [
            "context_id": context, "workspace_id": workspace,
        ], context: context)
        let revision = payload(before)["view_revision"] as? String
        for (tool, arguments) in [
            ("studio_set_camera", ["pan_x": 127] as [String: Any]),
            ("studio_set_camera", ["pan_x": 1e308, "pan_y": 0] as [String: Any]),
            ("studio_set_camera", ["mode": "fit_visible", "zoom": 1] as [String: Any]),
            ("studio_set_camera", ["zoom": 1, "transition_ms": -1] as [String: Any]),
            ("studio_set_camera", ["zoom": 1, "transition_ms": 1201] as [String: Any]),
            ("studio_set_camera", ["zoom": 1, "transition_ms": 0.5] as [String: Any]),
            ("studio_set_layout", ["left_pane": "not-a-pane"] as [String: Any]),
            ("studio_arrange_tables", ["operation": "compact", "table_ids": []] as [String: Any]),
            ("studio_arrange_tables", ["operation": "compact", "table_ids": ["posts", "posts"]] as [String: Any]),
            ("studio_arrange_tables", ["operation": "position", "table_ids": ["posts", "authors"], "x": 1, "y": 2] as [String: Any]),
            ("studio_arrange_tables", ["operation": "position", "table_ids": ["posts"], "x": 1e308, "y": 0] as [String: Any]),
            ("studio_update_workspace", ["changes": ["title": "ignored"]] as [String: Any]),
        ] {
            let response = await invoke(coordinator, tool, [
                "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            ].merging(arguments) { _, new in new }, context: context)
            #expect(errorCode(response) == "INVALID_ARGUMENT")
            let after = await invoke(coordinator, "studio_get_view", [
                "context_id": context, "workspace_id": workspace,
            ], context: context)
            #expect(payload(after)["view_revision"] as? String == revision)
        }
        let unsupportedWait = await invoke(coordinator, "studio_wait_events", [
            "context_id": context, "workspace_id": workspace, "presentation_id": "ignored-before",
            "wait_ms": 1,
        ], context: context)
        #expect(errorCode(unsupportedWait) == "TOOL_UNAVAILABLE")

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func graphToolsRevealTheirTargetAndReportActualFilteredVisibility() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-graph-view-contract-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await invoke(coordinator, "studio_connect_context", ["client_task_id": "graph-view-contract"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await invoke(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], context: context)
        let workspace = try #require(payload(opened)["workspace_id"] as? String)
        let tab = try #require(tabs.tabs.first { $0.id.uuidString == workspace })

        let scoped = await invoke(coordinator, "studio_show_tables", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "operation": "replace", "table_ids": ["authors"],
        ], context: context)
        #expect(payload(scoped)["visible_table_ids"] as? [String] == ["authors"])
        #expect(tab.session.automationViewportCommand?.fitVisibleTables == true)

        let table = await invoke(coordinator, "studio_open_table", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "table_id": "posts",
        ], context: context)
        #expect(table["isError"] as? Bool == false)
        #expect(tab.session.graphVisibleTableIDs.contains("posts"))
        #expect(tab.session.selectedGraphNodeIDs == ["posts"])

        tab.session.maximizedPaneSide = .right
        let revealed = await invoke(coordinator, "studio_show_tables", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "operation": "replace", "table_ids": ["posts"],
        ], context: context)
        #expect(revealed["isError"] as? Bool == false)
        #expect(tab.session.maximizedPaneSide == nil)
        #expect(tab.session.side(containing: .schema) == .left)

        tab.session.updateWorkspaceWidth(100)
        tab.session.setActivePaneSide(.right)
        let compactCamera = await invoke(coordinator, "studio_set_camera", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "mode": "fit_visible",
        ], context: context)
        #expect(compactCamera["isError"] as? Bool == false)
        #expect(tab.session.compactVisibleSide == .left)
        tab.session.updateWorkspaceWidth(2000)

        tab.session.maximizedPaneSide = .left
        let reopened = await invoke(coordinator, "studio_open_table", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "table_id": "authors",
        ], context: context)
        #expect(reopened["isError"] as? Bool == false)
        #expect(tab.session.maximizedPaneSide == nil)
        #expect(tab.session.paneState(for: tab.session.activePaneSide).kind == .tables)

        tab.session.maximizedPaneSide = .left
        let query = await invoke(coordinator, "studio_prepare_query", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "sql": "SELECT id FROM authors",
        ], context: context)
        #expect(query["isError"] as? Bool == false)
        #expect(tab.session.maximizedPaneSide == nil)
        #expect(tab.session.paneState(for: tab.session.activePaneSide).kind == .query)

        tab.session.maximizedPaneSide = .left
        let configured = await invoke(coordinator, "studio_configure_table", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "table_id": "authors", "sort": [["column_name": "id", "direction": "descending"]],
        ], context: context)
        #expect(configured["isError"] as? Bool == false)
        #expect(tab.session.maximizedPaneSide == nil)
        #expect(tab.session.paneState(for: tab.session.activePaneSide).kind == .tables)

        tab.session.showAllGraphTableCards = true
        let tableFromGraphCards = await invoke(coordinator, "studio_open_table", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "table_id": "posts",
        ], context: context)
        #expect(tableFromGraphCards["isError"] as? Bool == false)
        #expect(tab.session.showAllGraphTableCards == false)

        tab.session.restoreGraphFilterWithoutCounting(GraphTableFilter(minimumFields: 10_000))
        let hidden = await invoke(coordinator, "studio_show_tables", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "operation": "replace", "table_ids": ["authors"],
        ], context: context)
        #expect(payload(hidden)["visible_table_ids"] as? [String] == [])

        tab.session.clearGraphFilter()
        let camera = await invoke(coordinator, "studio_set_camera", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "mode": "fit_visible", "transition_ms": 900,
        ], context: context)
        #expect(camera["isError"] as? Bool == false)
        #expect(tab.session.automationViewportCommand?.fitVisibleTables == true)
        #expect(tab.session.automationViewportCommand?.transitionMilliseconds == 900)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func presentationKeyFocusIncludesItsTableAndDeclaredNeighbor() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-presentation-focus-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await invoke(coordinator, "studio_connect_context", ["client_task_id": "presentation-key-focus"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await invoke(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], context: context)
        let workspace = try #require(payload(opened)["workspace_id"] as? String)
        let tab = try #require(tabs.tabs.first { $0.id.uuidString == workspace })
        let edge = try #require(tab.session.graph.edges.first {
            $0.sourceID == "posts" && $0.targetID == "authors"
        })
        tab.session.setAutomationVisibleTableIDs(["authors"])

        let started = await invoke(coordinator, "studio_start_presentation", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "narration_mode": "disabled", "activation_intent": "foreground",
            "points": [["caption": "A post names its author", "actions": [[
                "type": "focus_keys", "table_id": "posts", "relation_id": edge.id,
            ]], "timing": ["advance": "manual"]]],
        ], context: context)
        #expect(started["isError"] as? Bool == false)
        for _ in 0..<100 where tab.session.automationFocusCommand?.relationID != edge.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.session.automationFocusCommand?.relationID == edge.id)
        #expect(tab.session.graphVisibleTableIDs.isSuperset(of: ["authors", "posts"]))

        // The next scope must dismiss this prior focus even when its root
        // remains among the visible tables.
        let scoped = await invoke(coordinator, "studio_show_tables", [
            "context_id": context, "workspace_id": workspace,
            "request_id": UUID().uuidString, "table_ids": ["authors", "posts"],
        ], context: context)
        #expect(scoped["isError"] as? Bool == false)
        #expect(tab.session.automationFocusCommand == nil)
        #expect(tab.session.automationFocusResetRevision > 0)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func presentationReturnRestoresTheTableAndPreviouslyActiveWorkspace() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-presentation-return-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let originalWorkspace = try #require(tabs.activeTabID)
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await invoke(coordinator, "studio_connect_context", ["client_task_id": "presentation-return"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await invoke(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString, "source_path": fixture.path,
            "activate": false,
        ], context: context)
        let workspace = try #require(payload(opened)["workspace_id"] as? String)
        let tab = try #require(tabs.tabs.first { $0.id.uuidString == workspace })
        #expect(tabs.activeTabID == originalWorkspace)

        let authors = await invoke(coordinator, "studio_open_table", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "table_id": "authors",
        ], context: context)
        #expect(authors["isError"] as? Bool == false)
        let originalTableTabID = tab.session.activeTabID
        tab.session.showAllGraphTableCards = true

        let started = await invoke(coordinator, "studio_start_presentation", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "narration_mode": "disabled", "activation_intent": "foreground",
            "points": [["caption": "Look at posts", "actions": [["type": "open_table", "table_id": "posts"]],
                        "timing": ["advance": "manual"]]],
        ], context: context)
        let presentationID = try #require(payload(started)["presentation_id"] as? String)
        #expect(tabs.activeTabID == tab.id)
        for _ in 0..<100 where tab.session.activeTab?.descriptor.name != "posts" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.session.activeTab?.descriptor.name == "posts")
        #expect(tab.session.showAllGraphTableCards == false)

        let returned = await invoke(coordinator, "studio_control_presentation", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "presentation_id": presentationID, "control": "return",
        ], context: context)
        #expect(returned["isError"] as? Bool == false)
        #expect(tab.session.activeTabID == originalTableTabID)
        #expect(tab.session.showAllGraphTableCards == true)
        #expect(tabs.activeTabID == originalWorkspace)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func presentationReturnClosesTheTableOpenedIntoAnEmptyPane() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-presentation-empty-return-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = await invoke(coordinator, "studio_connect_context", ["client_task_id": "presentation-empty-return"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let opened = await invoke(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], context: context)
        let workspace = try #require(payload(opened)["workspace_id"] as? String)
        let tab = try #require(tabs.tabs.first { $0.id.uuidString == workspace })
        #expect(tab.session.openTabs.isEmpty)
        tab.session.updateWorkspaceWidth(100)
        #expect(tab.session.compactVisibleSide == tab.session.side(containing: .schema))

        let started = await invoke(coordinator, "studio_start_presentation", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "narration_mode": "disabled", "activation_intent": "foreground",
            "points": [["caption": "Look at authors", "actions": [["type": "open_table", "table_id": "authors"]],
                        "timing": ["advance": "manual"]]],
        ], context: context)
        let presentationID = try #require(payload(started)["presentation_id"] as? String)
        for _ in 0..<100 where tab.session.activeTab?.descriptor.name != "authors" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.session.activeTab?.descriptor.name == "authors")
        #expect(tab.session.compactVisibleSide == tab.session.side(containing: .tables))

        let returned = await invoke(coordinator, "studio_control_presentation", [
            "context_id": context, "workspace_id": workspace, "request_id": UUID().uuidString,
            "presentation_id": presentationID, "control": "return",
        ], context: context)
        #expect(returned["isError"] as? Bool == false)
        #expect(tab.session.openTabs.isEmpty)
        #expect(tab.session.activeTab == nil)
        #expect(tab.session.compactVisibleSide == tab.session.side(containing: .schema))

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor private func invoke(_ coordinator: StudioAutomationCoordinator, _ name: String,
                                    _ arguments: [String: Any], context: String? = nil) async -> [String: Any] {
        let input = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        let output = await coordinator.handle(name, arguments: input, contextID: context,
                                              clientID: "tool-contract-client")
        return (try? JSONSerialization.jsonObject(with: output) as? [String: Any]) ?? [:]
    }

    private func payload(_ result: [String: Any]) -> [String: Any] {
        result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        (payload(result)["error"] as? [String: Any])?["code"] as? String
    }
}
