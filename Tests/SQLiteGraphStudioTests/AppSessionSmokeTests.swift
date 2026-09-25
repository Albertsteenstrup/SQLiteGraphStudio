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

        await tab.commitEdit(row: 0, columnName: "name", rawValue: "Smoke Test Author")?.value
        #expect(tab.row(at: 0)?.values[1] == .text("Smoke Test Author"))

        await tab.commitEdit(row: 0, columnName: "email", rawValue: "author2@example.com")?.value
        #expect((tab.inlineErrorMessage ?? "").contains("UNIQUE"))
    }

    @Test
    func sessionUsesTheSameNormalizedFileIdentityAsItsBackend() async throws {
        let url = try TestSupport.createFixture(named: "normalized-session")
        let aliasedURL = url.deletingLastPathComponent().appendingPathComponent("../" + url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: aliasedURL)
        #expect(session.databaseTarget == .sqlite(url.standardizedFileURL))
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
    func olderSavedPlacementRegeneratesCoordinatesButKeepsManualPins() async throws {
        let url = try TestSupport.createFixture(named: "older-placement")
        let suite = "SQLiteGraphStudioTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        await first.openDatabase(url: url)
        let pin = CGPoint(x: -120, y: 64)
        first.graphLayout.pin(nodeID: "authors", at: pin)
        first.persistCurrentGraphLayout()
        let key = try #require(defaults.dictionaryRepresentation().keys.first {
            $0.hasPrefix("SQLiteGraphStudio.graph-layout.v2.")
        })
        let saved = try #require(defaults.data(forKey: key))
        var legacy = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy.removeValue(forKey: "placementVersion")
        var positions = try #require(legacy["positions"] as? [String: [String: Double]])
        positions["posts"] = ["x": 10_000, "y": 10_000]
        legacy["positions"] = positions
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)

        let second = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        await second.openDatabase(url: url)
        #expect(second.graphLayout.position(for: "authors") == pin)
        #expect(second.graphLayout.position(for: "posts") != CGPoint(x: 10_000, y: 10_000))
        let migrated = try #require(defaults.data(forKey: key))
        let savedAgain = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(savedAgain["placementVersion"] as? Int == 4)
    }

    @Test
    func automationScopeAndRenderAcknowledgementTrackVisibleRevision() async throws {
        let url = try TestSupport.createFixture(named: "automation-visible-scope")
        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        let allTableIDs = Set(session.graph.nodes.map(\.id))
        let firstTableID = try #require(allTableIDs.sorted().first)

        session.setAutomationVisibleTableIDs([firstTableID, "not-in-this-schema"])
        let scopedRevision = session.automationViewRevision
        #expect(session.graphVisibleTableIDs == [firstTableID])

        session.acknowledgeAutomationViewRendered(
            revision: scopedRevision,
            displayedTableIDs: allTableIDs
        )
        #expect(session.automationRenderedViewRevision == scopedRevision)
        #expect(session.automationRenderedTableIDs == [firstTableID])

        session.markAutomationViewChanged()
        let changedRevision = session.automationViewRevision
        #expect(changedRevision > scopedRevision)
        #expect(session.automationRenderedViewRevision == nil)
        #expect(session.automationRenderedTableIDs.isEmpty)

        session.acknowledgeAutomationViewRendered(
            revision: scopedRevision,
            displayedTableIDs: allTableIDs
        )
        #expect(session.automationRenderedViewRevision == nil)

        session.acknowledgeAutomationViewRendered(
            revision: changedRevision,
            displayedTableIDs: [firstTableID]
        )
        #expect(session.automationRenderedViewRevision == changedRevision)
        #expect(session.automationRenderedTableIDs == [firstTableID])

        session.setAutomationVisibleTableIDs(nil)
        #expect(session.graphVisibleTableIDs == allTableIDs)
    }

    @Test
    func automationGroupsOverrideLayoutGroupingWithoutChangingSidecar() async throws {
        let url = try TestSupport.createFixture(named: "automation-group-override")
        let authored = SchemaSidecar(clusters: [
            .init(id: "authored", label: "Authored group", tables: ["authors"]),
        ])
        try SchemaSidecarStore.save(authored, for: url)
        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.graphGrouping.group(for: "authors")?.id == "authored")
        session.setAutomationGroups([
            .init(id: "temporary", label: "Temporary group", tables: ["posts"]),
        ])
        #expect(session.graphGrouping.group(for: "posts")?.id == "temporary")
        #expect(session.graphGrouping.group(for: "authors")?.id == "authored")
        #expect(session.schemaSidecar == authored)
        #expect(try SchemaSidecarStore.load(for: url).clusters == authored.clusters)

        session.setAutomationGroups(nil)
        #expect(session.graphGrouping.group(for: "authors")?.id == "authored")
        #expect(session.schemaSidecar == authored)
    }

    @Test
    func sessionReadsDescriptionsFromSidecar() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-descriptions")
        let sidecar = SchemaSidecar(
            tables: [
                "authors": .init(
                    description: "Author accounts and bylines.",
                    columns: ["email": "Public contact email."]
                ),
            ]
        )
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: SchemaSidecarStore.sidecarURL(for: url), options: .atomic)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.tableDescription(for: "authors") == "Author accounts and bylines.")
        #expect(session.columnDescription(for: "authors", column: "email") == "Public contact email.")
        #expect(session.hasAnyDescriptions)
    }

    @Test
    func sessionResolvesQueryResultColumnDescriptions() async throws {
        let url = try TestSupport.createFixture(named: "query-result-descriptions")
        let sidecar = SchemaSidecar(
            tables: [
                "authors": .init(
                    description: "Author accounts and bylines.",
                    columns: ["email": "Public contact email."]
                ),
                "posts": .init(
                    description: "Published and draft posts.",
                    columns: ["slug": "URL-safe public identifier."]
                ),
            ]
        )
        try SchemaSidecarStore.save(sidecar, for: url)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.descriptionForQueryResultColumn("authors.email") == "Public contact email.")
        #expect(session.descriptionForQueryResultColumn("email") == "authors.email: Public contact email.")
        #expect(session.descriptionForQueryResultColumn("posts") == "Published and draft posts.")
        #expect(session.descriptionForQueryResultColumn("missing") == nil)
    }

    @Test
    func sessionShowsRefreshToastWhenSidecarChanges() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-refresh-\(UUID().uuidString)")
        let sidecarURL = SchemaSidecarStore.sidecarURL(for: url)
        try? FileManager.default.removeItem(at: sidecarURL)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        #expect(session.refreshToast == nil)

        let sidecar = SchemaSidecar(
            tables: [
                "authors": .init(
                    description: "Author rows.",
                    columns: ["email": "Public contact email."]
                ),
            ]
        )
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: sidecarURL, options: .atomic)

        session.reloadSchemaSidecarFromDisk()

        #expect(session.refreshToast?.message == "Updated: +2 notes")
        #expect(session.tableDescription(for: "authors") == "Author rows.")
        #expect(session.columnDescription(for: "authors", column: "email") == "Public contact email.")

        session.dismissRefreshToast()
        session.reloadSchemaSidecarFromDisk()
        #expect(session.refreshToast == nil)
    }

    @Test
    func refreshSchemaReloadsSidecarAndShowsRefreshToast() async throws {
        let url = try TestSupport.createFixture(named: "schema-refresh-sidecar-\(UUID().uuidString)")
        let sidecarURL = SchemaSidecarStore.sidecarURL(for: url)
        let initialSidecar = SchemaSidecar(
            tables: [
                "authors": .init(description: "Original author note.")
            ]
        )
        try JSONEncoder().encode(initialSidecar).write(to: sidecarURL, options: .atomic)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        #expect(session.tableDescription(for: "authors") == "Original author note.")

        let updatedSidecar = SchemaSidecar(
            tables: [
                "authors": .init(description: "Updated author note.")
            ]
        )
        try JSONEncoder().encode(updatedSidecar).write(to: sidecarURL, options: .atomic)

        await session.refreshSchema()?.value

        #expect(session.tableDescription(for: "authors") == "Updated author note.")
        #expect(session.refreshToast?.message == "Updated: notes changed")
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

        let queryID = try #require(session.queryWorkspace.activeQuery?.id)
        await session.queryWorkspace.executionTask(for: queryID)?.value
        #expect((session.queryWorkspace.activeQuery?.result.rows.count ?? 0) > 0)
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
}
