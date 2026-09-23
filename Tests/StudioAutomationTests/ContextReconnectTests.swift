import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct ContextReconnectTests {
    @Test @MainActor
    func openSourceReceiptAndOwnershipSurviveStdioReconnect() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-context-reconnect-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        defer {
            Task { @MainActor in
                await coordinator.close()
                await tabs.closeAllAndWait()
            }
        }

        let connected = try await call(coordinator, "studio_connect_context",
                                       ["client_task_id": "task-reconnect"], client: "stdio-one")
        let contextID = try #require(content(connected)["context_id"] as? String)
        let token = try #require(content(connected)["resume_token"] as? String)
        let originalArguments: [String: Any] = [
            "context_id": contextID,
            "request_id": "open-source-once",
            "source_path": fixture.path,
        ]
        let original = try await rawCall(coordinator, "studio_open_source", originalArguments,
                                         client: "stdio-one", context: contextID)
        #expect(original.object["isError"] as? Bool == false)
        let sourceWorkspaceID = try #require(content(original.object)["workspace_id"] as? String)
        #expect(tabs.tabs.count == 2)

        let activeTakeover = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "task-reconnect", "resume_context_id": contextID,
            "resume_token": token,
        ], client: "stdio-two")
        #expect(errorCode(activeTakeover) == "CONTEXT_IN_USE")

        coordinator.disconnectClient("stdio-one")
        let wrongToken = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "task-reconnect", "resume_context_id": contextID,
            "resume_token": "wrong-secret",
        ], client: "stdio-two")
        #expect(errorCode(wrongToken) == "RESUME_DENIED")
        let wrongTask = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "different-task", "resume_context_id": contextID,
            "resume_token": token,
        ], client: "stdio-two")
        #expect(errorCode(wrongTask) == "RESUME_DENIED")

        let resumed = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "task-reconnect", "resume_context_id": contextID,
            "resume_token": token,
        ], client: "stdio-two")
        #expect(resumed["isError"] as? Bool == false)
        #expect(content(resumed)["context_id"] as? String == contextID)
        #expect(content(resumed)["workspace_id"] as? String == sourceWorkspaceID)
        let rotatedToken = try #require(content(resumed)["resume_token"] as? String)
        #expect(rotatedToken != token)

        let replay = try await rawCall(coordinator, "studio_open_source", originalArguments,
                                       client: "stdio-two", context: contextID)
        #expect(replay.data == original.data)
        #expect(tabs.tabs.count == 2)

        var changedArguments = originalArguments
        changedArguments["source_path"] = fixture.deletingLastPathComponent().path
        let conflict = try await call(coordinator, "studio_open_source", changedArguments,
                                      client: "stdio-two", context: contextID)
        #expect(errorCode(conflict) == "REQUEST_ID_CONFLICT")

        // Retention has a strict age bound even when the app remains open.
        coordinator.disconnectClient("stdio-two")
        coordinator.pruneRetainedState(now: Date().addingTimeInterval(25 * 60 * 60))
        let expired = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "task-reconnect", "resume_context_id": contextID,
            "resume_token": rotatedToken,
        ], client: "stdio-three")
        #expect(errorCode(expired) == "CONTEXT_EXPIRED")
    }

    @Test @MainActor
    func exportAndSaveExplanationOutcomesReplayFromTheStableContext() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-context-receipts-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-context-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: destination) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = try await call(coordinator, "studio_connect_context",
                                       ["client_task_id": "task-receipts"], client: "stdio-one")
        let contextID = try #require(content(connected)["context_id"] as? String)
        let token = try #require(content(connected)["resume_token"] as? String)
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": contextID, "request_id": "open-source", "source_path": fixture.path,
        ], client: "stdio-one", context: contextID)
        let workspaceID = try #require(content(opened)["workspace_id"] as? String)

        let exportArguments: [String: Any] = [
            "context_id": contextID,
            "workspace_id": workspaceID,
            "request_id": "export-posts-once",
            "object_type": "table_rows",
            "object_id": "posts",
            "format": "csv",
            "scope": ["kind": "all_matching"],
            "destination": destination.path,
        ]
        let originalExport = try await rawCall(coordinator, "studio_export", exportArguments,
                                               client: "stdio-one", context: contextID)
        #expect(originalExport.object["isError"] as? Bool == false)
        let exportJobID = try #require(content(originalExport.object)["job_id"] as? String)

        // An invalid presentation produces a stable error receipt without
        // needing a visible window in a headless automation test.
        let saveArguments: [String: Any] = [
            "context_id": contextID,
            "workspace_id": workspaceID,
            "request_id": "save-explanation-once",
            "presentation_id": "presentation:not-active",
            "title": "Reconnect receipt test",
        ]
        let originalSave = try await rawCall(coordinator, "studio_save_explanation", saveArguments,
                                             client: "stdio-one", context: contextID)
        #expect(errorCode(originalSave.object) == "OBJECT_NOT_FOUND")

        coordinator.disconnectClient("stdio-one")
        let resumed = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "task-receipts", "resume_context_id": contextID,
            "resume_token": token,
        ], client: "stdio-two")
        #expect(resumed["isError"] as? Bool == false)

        let exportReplay = try await rawCall(coordinator, "studio_export", exportArguments,
                                             client: "stdio-two", context: contextID)
        let saveReplay = try await rawCall(coordinator, "studio_save_explanation", saveArguments,
                                           client: "stdio-two", context: contextID)
        #expect(exportReplay.data == originalExport.data)
        #expect(saveReplay.data == originalSave.data)
        #expect(content(exportReplay.object)["job_id"] as? String == exportJobID)

        let job = try await call(coordinator, "studio_get_job", [
            "context_id": contextID, "workspace_id": workspaceID, "job_id": exportJobID,
        ], client: "stdio-two", context: contextID)
        #expect(content(job)["job_id"] as? String == exportJobID)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func reconnectDoesNotUndoNativeWorkspaceTransfer() async throws {
        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = try await call(coordinator, "studio_connect_context",
                                       ["client_task_id": "task-transfer"], client: "stdio-one")
        let contextID = try #require(content(connected)["context_id"] as? String)
        let token = try #require(content(connected)["resume_token"] as? String)
        let workspaceID = try #require(content(connected)["workspace_id"] as? String)
        coordinator.disconnectClient("stdio-one")

        tabs.activate(try #require(UUID(uuidString: workspaceID)))
        coordinator.releaseActiveWorkspaceForTransfer()
        let nextTask = try await call(coordinator, "studio_connect_context",
                                      ["client_task_id": "task-next"], client: "stdio-two")
        #expect(content(nextTask)["workspace_id"] as? String == workspaceID)

        let resumed = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "task-transfer", "resume_context_id": contextID,
            "resume_token": token,
        ], client: "stdio-three")
        #expect(resumed["isError"] as? Bool == false)
        #expect(content(resumed)["workspace_id"] is NSNull)
        #expect(content(resumed)["recovery_status"] as? String == "ownership_released")
        let visible = try await call(coordinator, "studio_list_workspaces", [
            "context_id": contextID,
        ], client: "stdio-three", context: contextID)
        #expect((content(visible)["workspaces"] as? [[String: Any]])?.isEmpty == true)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor
    private func rawCall(_ coordinator: StudioAutomationCoordinator, _ name: String,
                         _ arguments: [String: Any], client: String,
                         context: String? = nil) async throws -> (data: Data, object: [String: Any]) {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let output = await coordinator.handle(name, arguments: input, contextID: context, clientID: client)
        let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        return (output, object)
    }

    @MainActor
    private func call(_ coordinator: StudioAutomationCoordinator, _ name: String,
                      _ arguments: [String: Any], client: String,
                      context: String? = nil) async throws -> [String: Any] {
        try await rawCall(coordinator, name, arguments, client: client, context: context).object
    }

    private func content(_ result: [String: Any]) -> [String: Any] {
        result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        (content(result)["error"] as? [String: Any])?["code"] as? String
    }
}
