import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct QueryJobTests {
    @Test @MainActor
    func runQueryReturnsPromptlyAndPublishesSmallOwnedResultPreview() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-query-job-\(UUID().uuidString).sqlite")
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

        let contextID = try await connect(coordinator, client: "query-client", task: "query-task")
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": contextID, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], client: "query-client", context: contextID)
        #expect(opened["isError"] as? Bool == false)

        let startedAt = ContinuousClock.now
        let started = try await call(coordinator, "studio_run_query", [
            "context_id": contextID, "request_id": UUID().uuidString,
            "sql": "SELECT 7 AS answer",
        ], client: "query-client", context: contextID)
        let elapsed = startedAt.duration(to: .now)
        #expect(elapsed < .seconds(1))
        let startedContent = content(started)
        let jobID = try #require(startedContent["job_id"] as? String)
        #expect(startedContent["kind"] as? String == "query")

        let completed = try await waitForTerminalJob(coordinator, jobID: jobID,
                                                      client: "query-client", context: contextID)
        #expect(completed["status"] as? String == "completed")
        let resultID = try #require(completed["result_id"] as? String)
        let preview = try #require(completed["result_preview"] as? [String: Any])
        #expect(preview["row_count"] as? Int == 1)
        let columns = try #require(preview["columns"] as? [[String: Any]])
        #expect(columns.first?["name"] as? String == "answer")
        let rows = try #require(preview["rows"] as? [[String: Any]])
        let firstValues = try #require(rows.first?["values"] as? [[String: Any]])
        #expect(firstValues.first?["value"] as? String == "7")

        let shown = try await call(coordinator, "studio_show_query_results", [
            "context_id": contextID, "request_id": UUID().uuidString, "result_id": resultID,
        ], client: "query-client", context: contextID)
        #expect(shown["isError"] as? Bool == false)
        #expect(content(shown)["result_id"] as? String == resultID)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func cancellingSlowQueryWaitsForBackendAndNeverPublishesAResult() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-query-cancel-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let contextID = try await connect(coordinator, client: "query-cancel-client", task: "query-cancel-task")
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": contextID, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], client: "query-cancel-client", context: contextID)
        #expect(opened["isError"] as? Bool == false)

        let started = try await call(coordinator, "studio_run_query", [
            "context_id": contextID, "request_id": UUID().uuidString,
            "timeout_seconds": 30,
            "sql": "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 100000000) SELECT sum(x) AS total FROM n",
        ], client: "query-cancel-client", context: contextID)
        let jobID = try #require(content(started)["job_id"] as? String)

        let otherContextID = try await connect(coordinator, client: "other-query-client", task: "other-query-task")
        let denied = try await call(coordinator, "studio_cancel_job", [
            "context_id": otherContextID, "job_id": jobID, "request_id": UUID().uuidString,
        ], client: "other-query-client", context: otherContextID)
        #expect(denied["isError"] as? Bool == true)
        #expect(errorCode(denied) == "OBJECT_NOT_FOUND")
        let stillOwned = try await call(coordinator, "studio_get_job", [
            "context_id": contextID, "job_id": jobID,
        ], client: "query-cancel-client", context: contextID)
        #expect(["queued", "running"].contains(content(stillOwned)["status"] as? String ?? ""))

        let cancelled = try await call(coordinator, "studio_cancel_job", [
            "context_id": contextID, "job_id": jobID, "request_id": UUID().uuidString,
        ], client: "query-cancel-client", context: contextID)
        #expect(content(cancelled)["status"] as? String == "cancelled")
        #expect(content(cancelled)["result_id"] is NSNull)

        let reread = try await call(coordinator, "studio_get_job", [
            "context_id": contextID, "job_id": jobID,
        ], client: "query-cancel-client", context: contextID)
        #expect(content(reread)["status"] as? String == "cancelled")
        #expect(content(reread)["result_id"] is NSNull)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func sourceRefreshCancelsAnInFlightQueryAndDropsItsResult() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-query-refresh-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let contextID = try await connect(coordinator, client: "query-refresh-client", task: "query-refresh-task")
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": contextID, "request_id": UUID().uuidString, "source_path": fixture.path,
        ], client: "query-refresh-client", context: contextID)
        #expect(opened["isError"] as? Bool == false)

        let started = try await call(coordinator, "studio_run_query", [
            "context_id": contextID, "request_id": UUID().uuidString, "timeout_seconds": 30,
            "sql": "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 100000000) SELECT sum(x) AS total FROM n",
        ], client: "query-refresh-client", context: contextID)
        let jobID = try #require(content(started)["job_id"] as? String)

        let refreshed = try await call(coordinator, "studio_refresh_source", [
            "context_id": contextID, "request_id": UUID().uuidString,
        ], client: "query-refresh-client", context: contextID)
        #expect(refreshed["isError"] as? Bool == false)
        let job = try await call(coordinator, "studio_get_job", [
            "context_id": contextID, "job_id": jobID,
        ], client: "query-refresh-client", context: contextID)
        #expect(content(job)["status"] as? String == "cancelled")
        #expect(content(job)["result_id"] is NSNull)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func capturedQueryResultCannotBeExportedAfterTheWorkspaceChangesSource() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-stale-query-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.sqlite")
        let second = folder.appendingPathComponent("second.sqlite")
        try SampleFixtureBuilder.buildFixture(at: first)
        try SampleFixtureBuilder.buildFixture(at: second)

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let contextID = try await connect(coordinator, client: "stale-export-client", task: "stale-export-task")
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": contextID, "request_id": UUID().uuidString, "source_path": first.path,
        ], client: "stale-export-client", context: contextID)
        let workspaceID = try #require(content(opened)["workspace_id"] as? String)
        let query = try await call(coordinator, "studio_run_query", [
            "context_id": contextID, "request_id": UUID().uuidString, "sql": "SELECT 7 AS answer",
        ], client: "stale-export-client", context: contextID)
        let jobID = try #require(content(query)["job_id"] as? String)
        let completed = try await waitForTerminalJob(coordinator, jobID: jobID,
                                                       client: "stale-export-client", context: contextID)
        #expect(completed["status"] as? String == "completed")
        let resultID = try #require(completed["result_id"] as? String)
        let workspace = try #require(tabs.tabs.first { $0.id.uuidString == workspaceID })
        await workspace.session.openDocument(url: second)

        let destination = folder.appendingPathComponent("stale.csv")
        let exported = try await call(coordinator, "studio_export", [
            "context_id": contextID, "request_id": UUID().uuidString,
            "object_type": "query_result", "format": "csv", "destination": destination.path,
            "scope": ["kind": "captured", "result_id": resultID],
        ], client: "stale-export-client", context: contextID)
        #expect(errorCode(exported) == "STALE_SOURCE")
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor
    private func connect(_ coordinator: StudioAutomationCoordinator, client: String, task: String) async throws -> String {
        let connected = try await call(coordinator, "studio_connect_context", ["client_task_id": task], client: client)
        return try #require(content(connected)["context_id"] as? String)
    }

    @MainActor
    private func waitForTerminalJob(_ coordinator: StudioAutomationCoordinator, jobID: String,
                                    client: String, context: String) async throws -> [String: Any] {
        for _ in 0..<300 {
            let job = try await call(coordinator, "studio_get_job", [
                "context_id": context, "job_id": jobID,
            ], client: client, context: context)
            let payload = content(job)
            if let status = payload["status"] as? String,
               ["completed", "failed", "cancelled"].contains(status) { return payload }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueryJobTestError.didNotFinish
    }

    @MainActor
    private func call(_ coordinator: StudioAutomationCoordinator, _ name: String,
                      _ arguments: [String: Any], client: String,
                      context: String? = nil) async throws -> [String: Any] {
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

    private enum QueryJobTestError: Error {
        case didNotFinish
    }
}
