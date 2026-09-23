import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct ToolContractEdgeTests {
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
            ("studio_set_layout", ["left_pane": "not-a-pane"] as [String: Any]),
            ("studio_arrange_tables", ["operation": "compact", "table_ids": []] as [String: Any]),
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
