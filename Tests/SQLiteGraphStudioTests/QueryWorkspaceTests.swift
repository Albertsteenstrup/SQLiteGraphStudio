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
}
