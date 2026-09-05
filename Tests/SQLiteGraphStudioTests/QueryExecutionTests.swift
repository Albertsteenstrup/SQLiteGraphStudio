import Foundation
import Testing
@testable import StudioCore

struct QueryExecutionTests {
    @Test func sqliteCancellationInterruptsWorkAndAllowsReuse() async throws {
        let service = DatabaseService()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("query-execution-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.open(url: url)
        let task = Task {
            try await service.executeReadOnlyQuery(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n")
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled query completed successfully") } catch { }
        #expect(start.duration(to: .now) < .seconds(1))
        let result = try await service.executeReadOnlyQuery(sql: "SELECT 7")
        #expect(result.rows.first?.values == [.integer(7)])
        await service.close()
    }
    @Test func sqliteTimeoutAndExplainPreserveConnection() async throws {
        let service = DatabaseService()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("query-timeout-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.open(url: url)
        do {
            _ = try await service.executeReadOnlyQuery(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n", timeoutSeconds: 0.05)
            Issue.record("Expected SQLite timeout")
        } catch let error as DatabaseUserError { #expect(error.kind == .timeout) }
        let plan = try await service.explainQueryPlan(sql: "SELECT 1", timeoutSeconds: 1)
        #expect(!plan.isEmpty)
        let result = try await service.executeReadOnlyQuery(sql: "SELECT 8")
        #expect(result.rows.first?.values == [.integer(8)])
        await service.close()
    }

}

@MainActor
struct QueryExecutionWorkspaceTests {
    @Test func resultSnapshotSurvivesEditorChangesAndStopKeepsPreviousResult() async throws {
        let service = DatabaseService()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("query-workspace-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.open(url: url)
        let workspace = QueryWorkspaceModel(databaseService: service)
        workspace.loadSavedQueries(for: url)
        workspace.updateActiveSQL("SELECT 42")
        workspace.run()
        try await waitUntilIdle(workspace)
        #expect(workspace.activeQuery?.executedSQL == "SELECT 42")
        workspace.updateActiveSQL("SELECT 43")
        #expect(workspace.activeQuery?.executedSQL == "SELECT 42")
        workspace.updateActiveSQL("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n")
        workspace.run()
        try await Task.sleep(for: .milliseconds(20))
        workspace.stop()
        #expect(workspace.activeQuery?.isRunning == false)
        #expect(workspace.activeQuery?.result.rows.first?.values == [.integer(42)])
        #expect(workspace.activeQuery?.executedSQL == "SELECT 42")
        workspace.updateActiveSQL("SELECT 44")
        workspace.run()
        try await waitUntilIdle(workspace)
        #expect(workspace.activeQuery?.result.rows.first?.values == [.integer(44)])
        #expect(workspace.activeQuery?.executedSQL == "SELECT 44")
        await service.close()
    }

    @Test func reloadAndRepeatedRunsNeverPublishSupersededResults() async throws {
        let service = DatabaseService()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("query-reload-\(UUID()).sqlite")
        let suite = "query-reload-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: url); defaults.removePersistentDomain(forName: suite) }
        try await service.open(url: url)
        let workspace = QueryWorkspaceModel(databaseService: service, userDefaults: defaults)
        workspace.loadSavedQueries(for: url)
        workspace.updateActiveSQL("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n")
        workspace.setActiveQuerySaved(true)
        workspace.run()
        try await Task.sleep(for: .milliseconds(20))
        workspace.loadSavedQueries(for: url) // The saved document keeps the same UUID.
        workspace.updateActiveSQL("SELECT 99")
        workspace.run()
        workspace.explain()
        workspace.run()
        try await waitUntilIdle(workspace)
        #expect(workspace.activeQuery?.executedSQL == "SELECT 99")
        #expect(workspace.history.count == 1)
        #expect(workspace.activeQuery?.result.rows.first?.values == [.integer(99)])
        let id = try #require(workspace.activeQueryID)
        workspace.updateActiveSQL("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n")
        workspace.run()
        workspace.closeQuery(id: id)
        workspace.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(workspace.queries.isEmpty)
        #expect(workspace.history.isEmpty)
        await service.close()
    }

    private func waitUntilIdle(_ workspace: QueryWorkspaceModel) async throws {
        let start = ContinuousClock.now
        while workspace.activeQuery?.isRunning == true {
            guard start.duration(to: .now) < .seconds(3) else {
                Issue.record("Query did not finish")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.activeQuery?.errorMessage == nil)
    }
}
