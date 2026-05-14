import Foundation
import Testing
@testable import StudioCore

@MainActor
struct QueryWorkspaceTests {
    @Test
    func savedQueriesReloadForSameDatabase() {
        let defaultsSuiteName = "SQLiteGraphStudioTests.queries.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        let databaseURL = URL(fileURLWithPath: "/tmp/query-persistence.sqlite")

        do {
            let firstWorkspace = QueryWorkspaceModel(
                databaseService: DatabaseService(),
                userDefaults: userDefaults
            )
            firstWorkspace.loadSavedQueries(for: databaseURL)
            firstWorkspace.updateActiveTitle("Catalog")
            firstWorkspace.updateActiveSQL("SELECT name FROM sqlite_master ORDER BY name;")
            firstWorkspace.setActiveQuerySaved(true)

            _ = firstWorkspace.createQuery(
                title: "Top Posts",
                sqlText: "SELECT * FROM posts LIMIT 10;",
                activate: true,
                runImmediately: false,
                isSaved: true
            )
            _ = firstWorkspace.createQuery(
                title: "Scratch",
                sqlText: "SELECT 1;",
                activate: true,
                runImmediately: false,
                isSaved: false
            )

            let secondWorkspace = QueryWorkspaceModel(
                databaseService: DatabaseService(),
                userDefaults: userDefaults
            )
            secondWorkspace.loadSavedQueries(for: databaseURL)

            #expect(secondWorkspace.queries.count == 2)
            #expect(secondWorkspace.queries.map(\.title) == ["Catalog", "Top Posts"])
            #expect(secondWorkspace.queries.allSatisfy { $0.isSaved })
            #expect(secondWorkspace.activeQuery?.title == "Catalog")
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func queryHistoryAndExplainPlanAreRecordedPerDatabase() async throws {
        let url = try TestSupport.createFixture(named: "query-history")
        let defaultsSuiteName = "SQLiteGraphStudioTests.history.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let service = DatabaseService()
            try await service.open(url: url)
            let workspace = QueryWorkspaceModel(databaseService: service, userDefaults: userDefaults)
            workspace.loadSavedQueries(for: url)
            workspace.updateActiveTitle("Authors")
            workspace.updateActiveSQL("SELECT id, name FROM authors ORDER BY id LIMIT 2")
            workspace.run()

            try await waitFor {
                workspace.history.count == 1 && (workspace.activeQuery?.result.rows.count ?? 0) == 2
            }

            let entry = try #require(workspace.history.first)
            #expect(entry.title == "Authors")
            #expect(entry.rowCount == 2)
            #expect(entry.succeeded)

            workspace.explain()
            try await waitFor {
                workspace.activeQuery?.selectedOutput == .plan && !(workspace.activeQuery?.explainPlan.isEmpty ?? true)
            }

            let nextWorkspace = QueryWorkspaceModel(databaseService: service, userDefaults: userDefaults)
            nextWorkspace.loadSavedQueries(for: url)
            #expect(nextWorkspace.history.first?.title == "Authors")
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func queryHistoryCapsAtSevenAndCanRemoveEntries() async throws {
        let url = try TestSupport.createFixture(named: "query-history-cap")
        let defaultsSuiteName = "SQLiteGraphStudioTests.history-cap.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let service = DatabaseService()
            try await service.open(url: url)
            let workspace = QueryWorkspaceModel(databaseService: service, userDefaults: userDefaults)
            workspace.loadSavedQueries(for: url)

            for index in 1...9 {
                workspace.updateActiveTitle("Query \(index)")
                workspace.updateActiveSQL("SELECT \(index) AS value")
                workspace.run()
                try await waitFor {
                    workspace.history.first?.title == "Query \(index)"
                }
            }

            #expect(workspace.history.count == 7)
            #expect(workspace.history.first?.title == "Query 9")
            #expect(workspace.history.last?.title == "Query 3")

            let removedID = try #require(workspace.history.first?.id)
            workspace.removeHistoryEntry(id: removedID)
            #expect(workspace.history.count == 6)
            #expect(workspace.history.first?.title == "Query 8")

            workspace.clearHistory()
            #expect(workspace.history.isEmpty)
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private func waitFor(
        timeoutNanoseconds: UInt64 = 6_000_000_000,
        stepNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: stepNanoseconds)
        }
        Issue.record("Timed out waiting for condition")
        throw CancellationError()
    }
}
