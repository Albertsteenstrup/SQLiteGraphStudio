import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct WorkspaceOwnershipTests {
    @Test @MainActor
    func nativeHandoffDuringSourceOpenIsNotReclaimedByTheOpeningTask() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-workspace-open-handoff-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let openStarted = TestLatch()
        let coordinator = StudioAutomationCoordinator(workspaces: tabs) { session, url in
            openStarted.signal()
            try? await Task.sleep(for: .milliseconds(250))
            await session.openDocument(url: url)
        }
        defer {
            Task { @MainActor in
                await coordinator.close()
                await tabs.closeAllAndWait()
            }
        }

        let connectedA = try await call(coordinator, "studio_connect_context",
                                        ["client_task_id": "open-handoff-A"], client: "open-handoff-client-A")
        let contextA = try #require(content(connectedA)["context_id"] as? String)
        let opening = Task { @MainActor in
            let result = try await call(coordinator, "studio_open_source", [
                "context_id": contextA,
                "request_id": UUID().uuidString,
                "source_path": fixture.path,
                "activate": true,
            ], client: "open-handoff-client-A", context: contextA)
            return errorCode(result)
        }

        await openStarted.wait()
        let transferredWorkspaceID = try #require(tabs.activeTabID?.uuidString)
        coordinator.releaseActiveWorkspaceForTransfer()

        let connectedB = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "open-handoff-B",
            "workspace_id": transferredWorkspaceID,
        ], client: "open-handoff-client-B")
        let contextB = try #require(content(connectedB)["context_id"] as? String)
        let openErrorCode = try await opening.value

        #expect(openErrorCode == "WORKSPACE_OWNERSHIP_RELEASED")
        let workspacesB = try await call(coordinator, "studio_list_workspaces", [
            "context_id": contextB,
        ], client: "open-handoff-client-B", context: contextB)
        #expect((content(workspacesB)["workspaces"] as? [[String: Any]])?.map { $0["workspace_id"] as? String }
            == [transferredWorkspaceID])
        let schemaB = try await call(coordinator, "studio_describe_schema", [
            "context_id": contextB,
        ], client: "open-handoff-client-B", context: contextB)
        #expect(schemaB["isError"] as? Bool == false)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func oneTaskCannotDiscoverOrReadAnotherTasksSourceUntilNativeHandoff() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-workspace-ownership-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)

        let connectedA = try await call(coordinator, "studio_connect_context",
                                        ["client_task_id": "task-A"], client: "client-A")
        let contextA = try #require(content(connectedA)["context_id"] as? String)
        var resumeTokenA = try #require(content(connectedA)["resume_token"] as? String)
        let initialWorkspaceID = try #require(content(connectedA)["workspace_id"] as? String)
        let sourceA = try await call(coordinator, "studio_open_source",
                                     ["context_id": contextA, "request_id": UUID().uuidString,
                                      "source_path": fixture.path], client: "client-A", context: contextA)
        #expect(sourceA["isError"] as? Bool == false)
        let sourceWorkspaceID = try #require(content(sourceA)["workspace_id"] as? String)

        let connectedB = try await call(coordinator, "studio_connect_context",
                                        ["client_task_id": "task-B"], client: "client-B")
        let contextB = try #require(content(connectedB)["context_id"] as? String)
        let resumeTokenB = try #require(content(connectedB)["resume_token"] as? String)
        #expect((content(connectedB)["workspaces"] as? [[String: Any]])?.isEmpty == true)
        let listB = try await call(coordinator, "studio_list_workspaces",
                                   ["context_id": contextB], client: "client-B", context: contextB)
        #expect((content(listB)["workspaces"] as? [[String: Any]])?.isEmpty == true)
        #expect(content(listB)["active_workspace_id"] is NSNull)

        let stolen = try await call(coordinator, "studio_connect_context",
                                    ["client_task_id": "task-B", "workspace_id": sourceWorkspaceID],
                                    client: "client-B")
        #expect(stolen["isError"] as? Bool == true)
        #expect((content(stolen)["error"] as? [String: Any])?["code"] as? String == "WORKSPACE_IN_USE")
        let readB = try await call(coordinator, "studio_describe_schema",
                                   ["context_id": contextB, "workspace_id": sourceWorkspaceID],
                                   client: "client-B", context: contextB)
        #expect(readB["isError"] as? Bool == true)

        let listA = try await call(coordinator, "studio_list_workspaces",
                                   ["context_id": contextA], client: "client-A", context: contextA)
        #expect((content(listA)["workspaces"] as? [[String: Any]])?.count == 2)
        let backToInitial = try await call(coordinator, "studio_connect_context",
                                           ["client_task_id": "task-A", "resume_context_id": contextA,
                                            "resume_token": resumeTokenA, "workspace_id": initialWorkspaceID],
                                           client: "client-A")
        #expect(backToInitial["isError"] as? Bool == false)
        resumeTokenA = try #require(content(backToInitial)["resume_token"] as? String)
        let initialView = try await call(coordinator, "studio_get_view",
                                         ["context_id": contextA], client: "client-A", context: contextA)
        #expect(content(initialView)["workspace_id"] as? String == initialWorkspaceID)
        let listBAfterSwitch = try await call(coordinator, "studio_list_workspaces",
                                              ["context_id": contextB], client: "client-B", context: contextB)
        #expect((content(listBAfterSwitch)["workspaces"] as? [[String: Any]])?.isEmpty == true)
        let listAAfterSwitch = try await call(coordinator, "studio_list_workspaces",
                                              ["context_id": contextA], client: "client-A", context: contextA)
        #expect((content(listAAfterSwitch)["workspaces"] as? [[String: Any]])?.count == 2)
        let backToSource = try await call(coordinator, "studio_connect_context",
                                          ["client_task_id": "task-A", "resume_context_id": contextA,
                                           "resume_token": resumeTokenA, "workspace_id": sourceWorkspaceID],
                                          client: "client-A")
        #expect(backToSource["isError"] as? Bool == false)

        let sourceUUID = try #require(UUID(uuidString: sourceWorkspaceID))
        tabs.activate(sourceUUID)
        #expect(coordinator.canReleaseActiveWorkspaceForTransfer)
        coordinator.releaseActiveWorkspaceForTransfer()

        let availableToB = try await call(coordinator, "studio_list_workspaces",
                                          ["context_id": contextB], client: "client-B", context: contextB)
        #expect((content(availableToB)["workspaces"] as? [[String: Any]])?.map { $0["workspace_id"] as? String } == [sourceWorkspaceID])
        let attachedB = try await call(coordinator, "studio_connect_context",
                                       ["client_task_id": "task-B", "resume_context_id": contextB,
                                        "resume_token": resumeTokenB, "workspace_id": sourceWorkspaceID],
                                       client: "client-B")
        #expect(attachedB["isError"] as? Bool == false)
        let tablesB = try await call(coordinator, "studio_describe_schema",
                                     ["context_id": contextB], client: "client-B", context: contextB)
        #expect(tablesB["isError"] as? Bool == false)

        let listAAfter = try await call(coordinator, "studio_list_workspaces",
                                        ["context_id": contextA], client: "client-A", context: contextA)
        let visibleToA = (content(listAAfter)["workspaces"] as? [[String: Any]]) ?? []
        #expect(!visibleToA.contains { ($0["workspace_id"] as? String) == sourceWorkspaceID })
        let readAAfter = try await call(coordinator, "studio_describe_schema",
                                        ["context_id": contextA, "workspace_id": sourceWorkspaceID],
                                        client: "client-A", context: contextA)
        #expect(readAAfter["isError"] as? Bool == true)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor
    private func call(_ coordinator: StudioAutomationCoordinator, _ name: String,
                      _ arguments: [String: Any], client: String, context: String? = nil) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let output = await coordinator.handle(name, arguments: input, contextID: context, clientID: client)
        return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    private func content(_ result: [String: Any]) -> [String: Any] {
        result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        (content(result)["error"] as? [String: Any])?["code"] as? String
    }
}

@MainActor
private final class TestLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
