import Foundation
import Testing
@testable import StudioCore

@MainActor
struct WorkspaceRestorationTests {
    @Test
    func restoredTabsLoadOnlyWhenNeededAndPreserveDeferredSources() async throws {
        let url = try TestSupport.createFixture(named: "lazy-workspace-restore")
        let ids = (0..<6).map { _ in UUID() }
        let snapshot = WorkspaceRestorationSnapshot(
            tabs: ids.map { id in
                WorkspaceTabRestorationState(id: id, kind: .workspace, title: "Saved source",
                                             sourceDocumentPath: url.path,
                                             session: WorkspaceSessionRestorationState())
            },
            activeTabID: ids[0]
        )
        let controller = WorkspaceTabController(initialSession: AppSession())
        await controller.restoreWorkspace(from: snapshot)

        #expect(controller.tabs.count == 6)
        #expect(controller.liveDocumentCount == 1)
        #expect(controller.makeRestorationSnapshot().tabs.map(\.sourceDocumentPath) == Array(repeating: url.path, count: 6))

        for id in ids[1...3] { await controller.restoreDeferredTab(id) }
        #expect(controller.liveDocumentCount == 4)
        await controller.restoreDeferredTab(ids[4])
        #expect(controller.liveDocumentCount == 4)
        #expect(controller.tabs.first(where: { $0.id == ids[4] })?.session.databaseURL == nil)
        #expect(controller.makeRestorationSnapshot().tabs[4].sourceDocumentPath == url.path)

        await controller.closeAndWait(ids[1])
        await controller.restoreDeferredTab(ids[4])
        #expect(controller.liveDocumentCount == 4)
        #expect(controller.tabs.first(where: { $0.id == ids[4] })?.session.databaseURL == url.standardizedFileURL)
        await controller.closeAllAndWait()
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SQLiteGraphStudioTests.workspace-restoration.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makeMigrationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-migrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "create table customers (id bigint primary key, name text not null);"
            .write(to: directory.appendingPathComponent("0001_create_customers.sql"), atomically: true, encoding: .utf8)
        try "alter table customers add column email text;"
            .write(to: directory.appendingPathComponent("0002_add_email.sql"), atomically: true, encoding: .utf8)
        return directory
    }

    @Test
    func restorationSnapshotReopensTabsAndBrowsingStateWithoutReplayingQueries() async throws {
        let url = try TestSupport.createFixture(named: "workspace-restore")
        let originalSession = AppSession(databaseService: DatabaseService())
        let originalController = WorkspaceTabController(initialSession: originalSession)
        let originalTab = try #require(originalController.activeTab)
        await originalSession.openDatabase(url: url)

        originalSession.setPaneContent(.query, for: .left)
        originalSession.activePaneSide = .left
        originalSession.maximizedPaneSide = .right
        originalSession.workspaceSplitFraction = 0.37
        originalSession.graphZoom = 1.7
        originalSession.graphPan = CGSize(width: 120, height: -45)
        originalSession.selectedGraphNodeIDs = ["authors"]
        originalSession.selectedGraphNodeID = "authors"
        originalSession.expandedGraphNodeIDs = ["authors"]
        originalSession.restoreGraphFilterWithoutCounting(
            GraphTableFilter(minimumFields: 2, minimumRows: 3, maximumRows: 40)
        )

        let table = try #require(originalSession.openTable(named: "authors", autoLoad: false))
        originalSession.activePaneSide = .left
        table.queryState = TableQueryState(
            searchText: "Ada",
            columnFilters: [ColumnFilter(columnName: "name", value: "Ada", comparison: .contains)],
            sort: SortState(columnName: "name", direction: .descending),
            offset: 30,
            limit: 50
        )
        let draft = originalSession.queryWorkspace.createQuery(
            title: "Recent author draft",
            sqlText: "SELECT name FROM authors WHERE name LIKE '%Ada%';",
            runImmediately: false
        )
        if let draftIndex = originalSession.queryWorkspace.queries.firstIndex(where: { $0.id == draft.id }) {
            originalSession.queryWorkspace.queries[draftIndex].selectedOutput = .plan
        }

        let snapshot = originalController.makeRestorationSnapshot()
        #expect(snapshot.tabs.count == 1)
        #expect(snapshot.activeTabID == originalTab.id)
        #expect(snapshot.tabs[0].sourceDocumentPath == url.standardizedFileURL.path)
        #expect(snapshot.tabs[0].session.openTables.map(\.tableName) == ["authors"])

        let restoredSession = AppSession(databaseService: DatabaseService())
        let restoredController = WorkspaceTabController(initialSession: restoredSession)
        await restoredController.restoreWorkspace(from: snapshot)

        let restoredTab = try #require(restoredController.activeTab)
        let session = restoredTab.session
        #expect(restoredTab.id == originalTab.id)
        #expect(restoredTab.kind == originalTab.kind)
        #expect(session.databaseURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(session.leftPane.kind == .query)
        #expect(session.rightPane.kind == .tables)
        #expect(session.activePaneSide == .left)
        #expect(session.maximizedPaneSide == .right)
        #expect(abs(session.workspaceSplitFraction - 0.37) < 0.001)
        #expect(session.graphZoom == 1.7)
        #expect(session.graphPan == CGSize(width: 120, height: -45))
        #expect(session.selectedGraphNodeIDs == ["authors"])
        #expect(session.expandedGraphNodeIDs == ["authors"])
        #expect(session.graphTableFilter == GraphTableFilter(minimumFields: 2, minimumRows: 3, maximumRows: 40))

        let restoredTable = try #require(session.openTabs.first)
        #expect(restoredTable.descriptor.name == "authors")
        #expect(restoredTable.queryState.searchText == "Ada")
        #expect(restoredTable.queryState.columnFilters == [ColumnFilter(columnName: "name", value: "Ada", comparison: .contains)])
        #expect(restoredTable.queryState.sort == SortState(columnName: "name", direction: .descending))
        #expect(restoredTable.queryState.offset == 30)
        #expect(restoredTable.queryState.limit == 50)
        #expect(restoredTable.chunk.rows.isEmpty)

        let restoredDraft = try #require(session.queryWorkspace.queries.first(where: { $0.id == draft.id }))
        #expect(restoredDraft.sqlText == draft.sqlText)
        #expect(restoredDraft.selectedOutput == .plan)
        #expect(!restoredDraft.isRunning)
        #expect(restoredDraft.result == .empty)

        await restoredController.closeAllAndWait()
        await originalController.closeAllAndWait()
    }

    @Test
    func migrationFolderRestorationReopensAtTheSavedVersion() async throws {
        let directory = try makeMigrationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalSession = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        let originalController = WorkspaceTabController(initialSession: originalSession)
        await originalSession.openMigrations(at: directory, version: "0001")

        let snapshot = originalController.makeRestorationSnapshot()
        #expect(snapshot.tabs.first?.sourceDocumentPath == directory.standardizedFileURL.path)
        #expect(snapshot.tabs.first?.session.selectedMigrationVersion == "0001")

        let restoredController = WorkspaceTabController(
            initialSession: AppSession(databaseService: DatabaseService(), userDefaults: defaults),
            sessionFactory: { AppSession(databaseService: DatabaseService(), userDefaults: defaults) }
        )
        await restoredController.restoreWorkspace(from: snapshot)

        let restoredSession = try #require(restoredController.activeTab?.session)
        #expect(restoredSession.databaseTarget == .migrations(directory.standardizedFileURL))
        #expect(restoredSession.selectedMigrationVersion == "0001")
        #expect(restoredSession.migrationReplaySummary?.contains("1 of 2 migrations") == true)
        let customers = try #require(restoredSession.openTable(named: "public.customers", autoLoad: false))
        #expect(customers.descriptor.columns.map(\.name) == ["id", "name"])

        await restoredController.closeAllAndWait()
        await originalController.closeAllAndWait()
    }

    @Test
    func singleSQLSourceIsRestoredAsASchemaModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-schema-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("schema.sql")
        try "create table jobs (id bigint primary key, title text not null);"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let originalSession = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        let originalController = WorkspaceTabController(initialSession: originalSession)
        await originalSession.openDocument(url: sourceURL)

        let snapshot = originalController.makeRestorationSnapshot()
        #expect(snapshot.tabs.first?.sourceDocumentPath == sourceURL.standardizedFileURL.path)
        #expect(snapshot.tabs.first?.session.selectedMigrationVersion == "schema")

        let restoredController = WorkspaceTabController(
            initialSession: AppSession(databaseService: DatabaseService(), userDefaults: defaults),
            sessionFactory: { AppSession(databaseService: DatabaseService(), userDefaults: defaults) }
        )
        await restoredController.restoreWorkspace(from: snapshot)

        let restoredSession = try #require(restoredController.activeTab?.session)
        #expect(restoredSession.databaseTarget == .migrations(sourceURL.standardizedFileURL))
        #expect(restoredSession.selectedMigrationVersion == "schema")
        let jobs = try #require(restoredSession.openTable(named: "public.jobs", autoLoad: false))
        #expect(jobs.descriptor.columns.map(\.name) == ["id", "title"])

        await restoredController.closeAllAndWait()
        await originalController.closeAllAndWait()
    }

    @Test
    func missingSourceRemainsAsRecoverableTab() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).sqlite")
        let id = UUID()
        let snapshot = WorkspaceRestorationSnapshot(
            tabs: [WorkspaceTabRestorationState(
                id: id,
                kind: .workspace,
                title: "Orders",
                sourceDocumentPath: missingURL.path,
                session: WorkspaceSessionRestorationState()
            )],
            activeTabID: id
        )
        let controller = WorkspaceTabController(initialSession: AppSession(databaseService: DatabaseService()))

        await controller.restoreWorkspace(from: snapshot)

        #expect(controller.tabs.count == 1)
        #expect(controller.activeTab?.id == id)
        #expect(controller.activeTab?.title == "Orders")
        #expect(controller.activeTab?.session.presentedError?.kind == .notFound)
        #expect(controller.activeTab?.session.presentedError?.recoverySuggestion?.contains("locate the source again") == true)
    }

    @Test
    func storeRoundTripsVersionedSnapshotWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-store-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceRestorationStore(fileURL: directory.appendingPathComponent("restore.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let snapshot = WorkspaceRestorationSnapshot(
            tabs: [WorkspaceTabRestorationState(
                id: id,
                kind: .workspace,
                title: "Database",
                sourceDocumentPath: "/tmp/example.sqlite",
                session: WorkspaceSessionRestorationState(
                    unsavedQueryDrafts: [WorkspaceQueryDraft(
                        id: UUID(), title: "Draft", sqlText: "SELECT 1;", selectedOutput: QueryOutputKind.results.rawValue
                    )]
                )
            )],
            activeTabID: id
        )

        try store.save(snapshot)

        #expect(store.load() == snapshot)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let unsupportedVersion = WorkspaceRestorationSnapshot(version: 999, tabs: [], activeTabID: nil)
        #expect(throws: WorkspaceRestorationStoreError.self) {
            try store.save(unsupportedVersion)
        }
    }

    @Test
    func automaticRestorationSavesBrowsingChangesAndCanBeStopped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-autosave-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceRestorationStore(fileURL: directory.appendingPathComponent("restore.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WorkspaceTabController(initialSession: AppSession(databaseService: DatabaseService()))
        controller.enableAutomaticRestoration(using: store)
        let tab = try #require(controller.activeTab)
        tab.session.graphZoom = 1.4

        for _ in 0..<40 where store.load()?.tabs.first?.session.graphZoom != 1.4 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.load()?.tabs.first?.session.graphZoom == 1.4)

        controller.stopAutomaticRestoration()
        tab.session.graphZoom = 2.2
        try await Task.sleep(for: .milliseconds(550))
        #expect(store.load()?.tabs.first?.session.graphZoom == 1.4)
        await controller.closeAllAndWait()
    }
}
