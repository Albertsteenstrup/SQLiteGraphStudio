import Foundation
import Testing
@testable import StudioCore

@MainActor
struct AppSessionSmokeTests {
    @Test
    func sessionOpensDatabaseAndSurfacesEditFailures() async throws {
        let url = try TestSupport.createFixture(named: "session")
        let service = DatabaseService()
        let session = AppSession(databaseService: service)

        await session.openDatabase(url: url)
        #expect(session.databaseURL == url)
        #expect(!session.tables.isEmpty)

        let tab = try #require(session.openTable(named: "authors", autoLoad: false))
        await tab.reload()
        #expect(tab.chunk.totalRowCount == 8)

        tab.commitEdit(row: 0, columnName: "name", rawValue: "Smoke Test Author")
        try await waitFor {
            tab.row(at: 0)?.values[1] == .text("Smoke Test Author")
        }

        tab.commitEdit(row: 0, columnName: "email", rawValue: "author2@example.com")
        try await waitFor {
            (tab.inlineErrorMessage ?? "").contains("UNIQUE")
        }
    }

    @Test
    func sessionRestoresPersistedGraphLayoutForDatabase() async throws {
        let url = try TestSupport.createFixture(named: "persisted-layout")
        let defaultsSuiteName = "SQLiteGraphStudioTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let firstSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await firstSession.openDatabase(url: url)
            firstSession.graphLayout.pin(nodeID: "posts", at: CGPoint(x: 210, y: -40))
            firstSession.graphLayout.pin(nodeID: "authors", at: CGPoint(x: -120, y: 64))
            firstSession.persistCurrentGraphLayout()

            let secondSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await secondSession.openDatabase(url: url)

            #expect(secondSession.graphLayout.position(for: "posts") == CGPoint(x: 210, y: -40))
            #expect(secondSession.graphLayout.position(for: "authors") == CGPoint(x: -120, y: 64))
            #expect(secondSession.graphLayout.hasRestoredSnapshot)
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func sessionOpensAndRunsTopRowsQueryFromGraphAction() async throws {
        let url = try TestSupport.createFixture(named: "top-rows-query")
        let service = DatabaseService()
        let session = AppSession(databaseService: service)

        await session.openDatabase(url: url)
        session.runTopRowsQuery(for: "authors")

        #expect(session.leftPane.kind == .query || session.rightPane.kind == .query)
        #expect(session.queryWorkspace.queries.count >= 2)
        #expect(session.queryWorkspace.activeQuery?.sqlText.contains("LIMIT 10") == true)
        #expect(session.queryWorkspace.activeQuery?.title == "authors Top 10")

        try await waitFor {
            (session.queryWorkspace.activeQuery?.result.rows.count ?? 0) > 0
        }
    }

    @Test
    func sessionPersistsRecentDatabases() async throws {
        let url = try TestSupport.createFixture(named: "recent-databases")
        let defaultsSuiteName = "SQLiteGraphStudioTests.recents.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let firstSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await firstSession.openDatabase(url: url)
            #expect(firstSession.recentDatabaseURLs.first == url.standardizedFileURL)

            let secondSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            #expect(secondSession.recentDatabaseURLs.first == url.standardizedFileURL)
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private func waitFor(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
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
