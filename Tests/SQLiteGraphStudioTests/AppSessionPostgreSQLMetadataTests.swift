import Foundation
import Testing
@testable import StudioCore

@MainActor
struct AppSessionPostgreSQLMetadataTests {
    @Test(arguments: ["postgres", "pgstudio"])
    func postgresDocumentLoadsSiblingMetadataWithoutOpeningDatabase(fileExtension: String) async throws {
        let fixture = try makeFixture(fileExtension: fileExtension)
        defer { fixture.cleanUp() }
        let sidecar = metadata(description: "Order records.")
        try SchemaSidecarStore.save(sidecar, for: fixture.documentURL)
        let documentBefore = try Data(contentsOf: fixture.documentURL)
        let service = DatabaseService()
        let session = AppSession(databaseService: service, userDefaults: fixture.defaults)

        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)

        #expect(session.databaseURL == fixture.documentURL)
        #expect(session.databaseTarget == target)
        #expect(session.schemaSidecar == sidecar)
        #expect(session.tableDescription(for: "public.orders") == "Order records.")
        #expect(session.columnDescription(for: "public.orders", column: "external_ref") == "Checkout reference.")
        #expect(session.stories.first?.playback.first?.tables == ["public.orders"])
        #expect(SchemaSidecarStore.sidecarURL(for: fixture.documentURL).lastPathComponent == "catalog.\(fileExtension).studio.json")
        #expect(try Data(contentsOf: fixture.documentURL) == documentBefore)
        #expect(await service.currentTarget == nil)
    }

    @Test
    func postgresMetadataReloadUsesDocumentAndPreservesNodePositions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)
        session.graphLayout.pin(nodeID: "public.orders", at: CGPoint(x: 120, y: -60))
        let updated = metadata(description: "Updated order records.")
        try SchemaSidecarStore.save(updated, for: fixture.documentURL)

        session.reloadSchemaSidecarFromDisk()

        #expect(session.schemaSidecar == updated)
        #expect(session.clusterLabel(for: "public.orders") == "Commerce")
        #expect(session.graphLayout.position(for: "public.orders") == CGPoint(x: 120, y: -60))
        #expect(session.refreshToast != nil)
    }

    @Test
    func sessionCachesResolvedGroupsWhileKeepingAuthoredSidecarUnchanged() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let authored = metadata(description: "Order records.")
        try SchemaSidecarStore.save(authored, for: fixture.documentURL)
        let session = AppSession(userDefaults: fixture.defaults)

        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)

        #expect(session.graphGrouping.group(for: "public.orders")?.id == "commerce")
        #expect(session.graphGrouping.group(for: "public.customers")?.isInferred == true)
        #expect(session.clusterColorHex(for: "public.orders") == "#7CC3FF")
        #expect(session.schemaSidecar == authored)
        #expect(try SchemaSidecarStore.load(for: fixture.documentURL) == authored)

        var updated = authored
        updated.clusters = [.init(id: "sales", label: "Sales", tables: ["public.orders"], color: "#F8B26A")]
        try SchemaSidecarStore.save(updated, for: fixture.documentURL)
        session.reloadSchemaSidecarFromDisk()

        #expect(session.graphGrouping.group(id: "commerce") == nil)
        #expect(session.clusterLabel(for: "public.orders") == "Sales")
        #expect(session.clusterColorHex(for: "public.orders") == "#F8B26A")
        #expect(session.schemaSidecar == updated)
        session.closeDatabase()
        #expect(session.graphGrouping == .empty)
    }

    @Test
    func postgresStoryDeletionWritesOnlySiblingMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sidecar = metadata(description: "Order records.")
        try SchemaSidecarStore.save(sidecar, for: fixture.documentURL)
        let documentBefore = try Data(contentsOf: fixture.documentURL)
        let service = DatabaseService()
        let session = AppSession(databaseService: service, userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)
        session.schemaSidecar = sidecar

        session.deleteStory(id: "checkout")

        let saved = try SchemaSidecarStore.load(for: fixture.documentURL)
        #expect(saved.stories.isEmpty)
        #expect(saved.tables == sidecar.tables)
        #expect(saved.clusters == sidecar.clusters)
        #expect(session.stories.isEmpty)
        #expect(session.refreshToast?.message == "Updated: -1 story")
        #expect(try Data(contentsOf: fixture.documentURL) == documentBefore)
        #expect(await service.currentTarget == nil)
    }

    @Test
    func switchingDocumentsForSameConnectionReplacesLocalMetadataAndTransientSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let secondURL = fixture.documentURL.deletingLastPathComponent().appendingPathComponent("other.pgstudio")
        try Data(contentsOf: fixture.documentURL).write(to: secondURL)
        try SchemaSidecarStore.save(metadata(description: "First document."), for: fixture.documentURL)
        try SchemaSidecarStore.save(metadata(description: "Second document."), for: secondURL)
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)
        session.selectedGraphNodeIDs = ["public.orders"]
        _ = session.openTable(named: "public.orders", autoLoad: false)

        session.apply(snapshot: snapshot(), target: target, documentURL: secondURL)

        #expect(session.databaseTarget == target)
        #expect(session.databaseURL == secondURL)
        #expect(session.tableDescription(for: "public.orders") == "Second document.")
        #expect(session.selectedGraphNodeIDs.isEmpty)
        #expect(session.openTabs.isEmpty)
        #expect(session.recentDatabaseURLs == [secondURL, fixture.documentURL])

        session.closeDatabase()

        #expect(session.databaseURL == nil)
        #expect(session.databaseTarget == nil)
        #expect(session.schemaSidecar == .empty)
        #expect(session.selectedGraphNodeIDs.isEmpty)
        #expect(session.skillsDirectory == nil)
        #expect(session.databaseCapabilities == .none)
    }

    @Test
    func queuedPostgresRefreshDoesNotRestoreBusyStateAfterClose() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)

        session.refreshSchema()
        session.closeDatabase()
        try await Task.sleep(for: .milliseconds(25))

        #expect(!session.isRefreshing)
        #expect(session.databaseTarget == nil)
        #expect(session.databaseURL == nil)
        #expect(session.presentedError == nil)
    }

    @Test
    func applyingRefreshedCatalogForSameDocumentPreservesMultipleSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)
        session.selectedGraphNodeIDs = ["public.orders"]

        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)

        #expect(session.selectedGraphNodeIDs == ["public.orders"])
    }

    @Test
    func postgresCapabilitiesEnableLocalSkillsAndKeepAllDatabaseWritesDisabled() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)

        let capabilities = session.databaseCapabilities
        #expect(capabilities == .postgresReadOnly)
        #expect(capabilities.isReadOnly)
        #expect(capabilities.supportsAIWorkspace)
        #expect(!capabilities.canEditRows)
        #expect(!capabilities.canInsertRows)
        #expect(!capabilities.canDeleteRows)
        #expect(!capabilities.canImportRows)
        #expect(!capabilities.canCreateTable)
        #expect(!capabilities.canAlterSchema)
        #expect(!capabilities.canDropColumns)
        #expect(!capabilities.canWriteSQL)
        #expect(session.skillsDirectory == fixture.documentURL.deletingLastPathComponent())
        session.showSkills()
        #expect(session.isSkillsPresented)
        session.showCreateTable()
        #expect(!session.isCreateTablePresented)

        let installationTarget = try #require(StudioSkills.targetDirectories.first { $0.subpath == ".agents/skills" })
        session.installSkills(to: installationTarget)
        #expect(session.skillsInstalled)
    }

    @Test
    func recentsRestorePostgresDocumentsAndSQLiteFilesAndFilterMissingFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = fixture.documentURL.deletingLastPathComponent()
        let alternate = root.appendingPathComponent("catalog.PGSTUDIO")
        let sqlite = root.appendingPathComponent("catalog.sqlite")
        let missing = root.appendingPathComponent("missing.postgres")
        let unsupported = root.appendingPathComponent("notes.txt")
        for url in [alternate, sqlite, unsupported] { try Data().write(to: url) }
        fixture.defaults.set(
            [fixture.documentURL, alternate, sqlite, missing, unsupported].map(\.path),
            forKey: "SQLiteGraphStudio.recent-databases"
        )

        let session = AppSession(userDefaults: fixture.defaults)

        #expect(session.recentDatabaseURLs == [fixture.documentURL, alternate, sqlite])
    }

    @Test
    func recentPostgresDocumentUsesDocumentDecoder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let invalidDocument = Data("{}".utf8)
        try invalidDocument.write(to: fixture.documentURL)
        fixture.defaults.set([fixture.documentURL.path], forKey: "SQLiteGraphStudio.recent-databases")
        let session = AppSession(userDefaults: fixture.defaults)
        let expectedError: String
        do {
            _ = try JSONDecoder().decode(PostgresConnectionDocument.self, from: invalidDocument)
            Issue.record("Expected malformed document to fail decoding")
            return
        } catch { expectedError = error.localizedDescription }

        session.openRecentDatabase(fixture.documentURL)
        for _ in 0..<200 where session.presentedError == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(session.presentedError?.message == expectedError)
        #expect(session.databaseTarget == nil)
        #expect(try Data(contentsOf: fixture.documentURL) == invalidDocument)
    }

    @Test
    func resultDescriptionsMatchLongestKnownTablePrefixAndColumnNamesContainingDots() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let session = AppSession(userDefaults: fixture.defaults)
        session.schemaSidecar = SchemaSidecar(tables: [
            "public": .init(description: "A different table.", columns: ["orders.amount.net": "Wrong prefix."]),
            "public.orders": .init(description: "Order records.", columns: ["amount.net": "Net total.", "id": "Order ID."]),
            "public.pending_orders": .init(columns: ["id": "Pending order ID."]),
            "orders": .init(columns: ["id": "SQLite order ID."]),
            "event.log": .init(columns: ["created.at": "Event timestamp."]),
        ])

        #expect(session.descriptionForQueryResultColumn(" public.orders.amount.net ") == "Net total.")
        #expect(session.descriptionForQueryResultColumn("public.orders") == "Order records.")
        #expect(session.descriptionForQueryResultColumn("public.pending_orders") == nil)
        #expect(session.descriptionForQueryResultColumn("public.orders.id") == "Order ID.")
        #expect(session.descriptionForQueryResultColumn("orders.id") == "SQLite order ID.")
        #expect(session.descriptionForQueryResultColumn("event.log.created.at") == "Event timestamp.")
        #expect(session.descriptionForQueryResultColumn("id") == nil)
        #expect(session.descriptionForQueryResultColumn("missing") == nil)
    }

    @Test
    func unqualifiedResultColumnDoesNotGuessWhenCatalogContainsMultipleMatches() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: snapshot(), target: target, documentURL: fixture.documentURL)
        session.schemaSidecar = SchemaSidecar(tables: [
            "public.orders": .init(columns: ["id": "Order ID.", "external_ref": "Checkout reference."]),
        ])

        #expect(session.descriptionForQueryResultColumn("id") == nil)
        #expect(session.descriptionForQueryResultColumn("external_ref") == "public.orders.external_ref: Checkout reference.")
    }

    @Test(arguments: [false, true])
    func unqualifiedColumnDescriptionsPreserveSQLiteAndPostgresAmbiguityRules(isPostgres: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let names = isPostgres ? ["public.authors", "reporting.authors"] : ["authors", "reviewers"]
        let descriptors = names.enumerated().map { index, name in
            EditableTableDescriptor(
                name: name,
                schemaName: isPostgres ? (index == 0 ? "public" : "reporting") : nil,
                objectName: isPostgres ? "authors" : name,
                objectType: .table,
                columns: [.init(name: "email", declaredType: "text", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0)],
                primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false
            )
        }
        let catalog = CatalogSnapshot(descriptors: descriptors, graph: SchemaGraph(
            nodes: names.map { GraphNode(id: $0, title: $0, isEditable: false) }, edges: []
        ))
        let sqliteURL = fixture.documentURL.deletingLastPathComponent().appendingPathComponent("catalog.sqlite")
        let session = AppSession(userDefaults: fixture.defaults)
        session.apply(snapshot: catalog, target: isPostgres ? target : .sqlite(sqliteURL))
        session.schemaSidecar = SchemaSidecar(tables: [
            names[0]: .init(columns: ["email": "Public contact email."]),
        ])

        #expect(session.descriptionForQueryResultColumn(names[0] + ".email") == "Public contact email.")
        let expected = isPostgres ? nil : "authors.email: Public contact email."
        #expect(session.descriptionForQueryResultColumn("email") == expected)

        session.schemaSidecar.tables[names[1]] = .init(columns: ["email": "Review contact email."])
        #expect(session.descriptionForQueryResultColumn("email") == nil)
    }

    private var target: DatabaseTarget {
        .postgres(.init(host: "localhost", database: "catalog", username: "reader", tlsMode: .disabled))
    }

    private func metadata(description: String) -> SchemaSidecar {
        SchemaSidecar(
            clusters: [.init(id: "commerce", label: "Commerce", tables: ["public.orders"], color: "#7CC3FF")],
            tables: ["public.orders": .init(description: description, columns: ["external_ref": "Checkout reference."])],
            stories: [.init(id: "checkout", title: "Checkout", createdAt: "2026-09-05T10:00:00Z", playback: [
                .init(text: "The order captures checkout.", tables: ["public.orders"], focus: "public.orders"),
            ])]
        )
    }

    private func snapshot() -> CatalogSnapshot {
        let descriptors = ["orders", "customers"].map { objectName in
            EditableTableDescriptor(
                name: "public.\(objectName)", schemaName: "public", objectName: objectName, objectType: .table,
                columns: (objectName == "orders" ? ["id", "external_ref"] : ["id"]).map { name in
                    TableColumn(name: name, declaredType: "text", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0)
                }, primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false
            )
        }
        return CatalogSnapshot(descriptors: descriptors, graph: SchemaGraph(
            nodes: descriptors.map { GraphNode(id: $0.name, title: $0.name, isEditable: false) }, edges: []
        ))
    }

    private struct Fixture {
        let documentURL: URL
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: documentURL.deletingLastPathComponent())
        }
    }

    private func makeFixture(fileExtension: String = "postgres") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PostgresMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("catalog.\(fileExtension)")
        let document = PostgresConnectionDocument(host: "localhost", database: "catalog", username: "reader", tlsMode: .disabled)
        try JSONEncoder().encode(document).write(to: url)
        let suiteName = "SQLiteGraphStudioTests.metadata.\(UUID().uuidString)"
        return Fixture(documentURL: url, defaults: try #require(UserDefaults(suiteName: suiteName)), suiteName: suiteName)
    }
}
