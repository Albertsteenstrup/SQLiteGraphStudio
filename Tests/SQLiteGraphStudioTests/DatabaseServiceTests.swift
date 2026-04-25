import Foundation
import Testing
@testable import StudioCore

struct DatabaseServiceTests {
    @Test
    func catalogSnapshotCapturesEditableAndReadOnlyTables() async throws {
        let url = try TestSupport.createFixture(named: "catalog")
        let service = DatabaseService()
        try await service.open(url: url)

        let snapshot = try await service.loadCatalogSnapshot()
        let descriptors = Dictionary(uniqueKeysWithValues: snapshot.descriptors.map { ($0.name, $0) })

        let authors = try #require(descriptors["authors"])
        #expect(authors.objectType == .table)
        #expect(authors.isEditable)
        #expect(authors.rowIdentityStrategy == .primaryKey)
        #expect(authors.rowCount == 8)

        let authorProfiles = try #require(descriptors["author_profiles"])
        #expect(authorProfiles.objectType == .view)
        #expect(!authorProfiles.isEditable)
        #expect(authorProfiles.rowIdentityStrategy == .readOnly)
        #expect(authorProfiles.rowCount == 8)

        let syncMarkers = try #require(descriptors["sync_markers"])
        #expect(syncMarkers.isWithoutRowID)
        #expect(syncMarkers.isEditable)
        #expect(syncMarkers.rowIdentityStrategy == .primaryKey)

        let posts = try #require(descriptors["posts"])
        #expect(posts.indexes.contains { $0.name == "idx_posts_status" && $0.columns == ["status"] })
        #expect(posts.triggers.contains { $0.name == "posts_touch_updated_at" })
        #expect(posts.constraints.contains { $0.kind == .check && $0.detail.contains("CHECK") })
        #expect(posts.constraints.contains { $0.kind == .foreignKey && $0.columns == ["author_id"] })

        let generatedMetrics = try #require(descriptors["generated_metrics"])
        #expect(generatedMetrics.generatedColumns.map(\.name) == ["doubled_value"])
    }

    @Test
    func schemaGraphUsesDeclaredForeignKeys() async throws {
        let url = try TestSupport.createFixture(named: "graph")
        let service = DatabaseService()
        try await service.open(url: url)

        let graph = try await service.loadSchemaGraph()
        let edgePairs = Set(graph.edges.map { "\($0.sourceID)->\($0.targetID)" })

        #expect(edgePairs.contains("posts->authors"))
        #expect(edgePairs.contains("comments->posts"))
        #expect(edgePairs.contains("comments->comments"))
        #expect(edgePairs.contains("categories->categories"))
        #expect(!edgePairs.contains("author_profiles->authors"))
    }

    @Test
    func fetchChunkPagesLargeTablesWithoutLoadingEverything() async throws {
        let url = try TestSupport.createFixture(named: "paging")
        let service = DatabaseService()
        try await service.open(url: url)

        let descriptor = try await service.fetchDescriptor(named: "event_log")
        let chunk = try await service.fetchChunk(
            query: TableQueryState(offset: 5_000, limit: 250),
            descriptor: descriptor
        )

        #expect(chunk.totalRowCount == 100_000)
        #expect(chunk.rows.count == 250)
        #expect(chunk.offset == 5_000)

        let firstValue = try #require(chunk.rows.first?.values.first)
        #expect(firstValue == .integer(5_001))
    }

    @Test
    func commitEditPersistsAndConstraintErrorsSurface() async throws {
        let url = try TestSupport.createFixture(named: "edits")
        let service = DatabaseService()
        try await service.open(url: url)

        let authors = try await service.fetchDescriptor(named: "authors")
        let initialChunk = try await service.fetchChunk(query: TableQueryState(limit: 5), descriptor: authors)
        let firstRow = try #require(initialChunk.rows.first)

        try await service.commitEdit(
            CellEditChange(
                descriptor: authors,
                rowIdentity: firstRow.identity,
                columnName: "name",
                rawValue: "Renamed Author"
            )
        )

        let refreshedChunk = try await service.fetchChunk(query: TableQueryState(limit: 5), descriptor: authors)
        #expect(refreshedChunk.rows.first?.values[1] == .text("Renamed Author"))

        await #expect(throws: SQLiteUserError.self) {
            try await service.commitEdit(
                CellEditChange(
                    descriptor: authors,
                    rowIdentity: firstRow.identity,
                    columnName: "email",
                    rawValue: "author2@example.com"
                )
            )
        }
    }

    @Test
    func readOnlyQueryModeReturnsRowsAndRejectsWrites() async throws {
        let url = try TestSupport.createFixture(named: "query-mode")
        let service = DatabaseService()
        try await service.open(url: url)

        let result = try await service.executeReadOnlyQuery(
            sql: """
            SELECT id, name
            FROM authors
            ORDER BY id
            LIMIT 2
            """
        )

        #expect(result.columns.map(\.name) == ["id", "name"])
        #expect(result.rows.count == 2)
        #expect(result.rows.first?.values == [.integer(1), .text("Author 1")])

        await #expect(throws: SQLiteUserError.self) {
            try await service.executeReadOnlyQuery(sql: "DELETE FROM authors WHERE id = 1")
        }
    }

    @Test
    func dropColumnUpdatesSchemaSnapshot() async throws {
        let url = try TestSupport.createFixture(named: "drop-column")
        let service = DatabaseService()
        try await service.open(url: url)

        let descriptor = try await service.fetchDescriptor(named: "authors")
        try await service.dropColumn(columnName: "bio", from: descriptor)

        let refreshed = try await service.fetchDescriptor(named: "authors")
        #expect(!refreshed.columns.contains(where: { $0.name == "bio" }))
        #expect(refreshed.columns.contains(where: { $0.name == "name" }))
    }

    @Test
    func importAndExportRowsSupportCSVAndJSON() async throws {
        let url = try TestSupport.createFixture(named: "import-export")
        let service = DatabaseService()
        try await service.open(url: url)

        let descriptor = try await service.fetchDescriptor(named: "tags")
        let csv = """
        id,name
        101,"quoted, tag"
        102,json-ready
        """
        let importResult = try await service.importRows(into: descriptor, text: csv, format: .csv)
        #expect(importResult.insertedRowCount == 2)
        #expect(importResult.skippedRowCount == 0)

        let chunk = try await service.fetchChunk(
            query: TableQueryState(searchText: "quoted", limit: 20),
            descriptor: descriptor
        )
        #expect(chunk.rows.contains { $0.values == [.integer(101), .text("quoted, tag")] })

        let exportedCSV = try await service.serializeTableRows(descriptor: descriptor, rows: chunk.rows, format: .csv)
        #expect(exportedCSV.contains("\"quoted, tag\""))

        let json = """
        [{"id": 103, "name": "json tag"}]
        """
        let jsonImport = try await service.importRows(into: descriptor, text: json, format: .json)
        #expect(jsonImport.insertedRowCount == 1)

        let queryResult = try await service.executeReadOnlyQuery(sql: "SELECT id, name FROM tags WHERE id >= 101 ORDER BY id")
        let exportedJSON = try await service.serializeQueryResult(queryResult, format: .json)
        #expect(exportedJSON.contains("json tag"))
    }

    @Test
    func explainPlanAndSQLiteNativeDDLWorkflows() async throws {
        let url = try TestSupport.createFixture(named: "ddl")
        let service = DatabaseService()
        try await service.open(url: url)

        let plan = try await service.explainQueryPlan(sql: "SELECT * FROM authors WHERE id = 1")
        #expect(!plan.isEmpty)
        #expect(plan.contains { $0.detail.localizedCaseInsensitiveContains("authors") })

        try await service.createTable(
            TableCreateDraft(
                tableName: "scratch_items",
                columns: [
                    TableColumnDraft(name: "id", type: "INTEGER", isPrimaryKey: true),
                    TableColumnDraft(name: "title", type: "TEXT", isNotNull: true),
                ]
            )
        )

        var descriptor = try await service.fetchDescriptor(named: "scratch_items")
        #expect(descriptor.columns.map(\.name) == ["id", "title"])

        try await service.addColumn(TableColumnDraft(name: "notes", type: "TEXT"), to: descriptor)
        descriptor = try await service.fetchDescriptor(named: "scratch_items")
        #expect(descriptor.columns.contains { $0.name == "notes" })

        try await service.renameColumn(from: "notes", to: "body", in: descriptor)
        descriptor = try await service.fetchDescriptor(named: "scratch_items")
        #expect(descriptor.columns.contains { $0.name == "body" })

        try await service.renameTable(from: "scratch_items", to: "renamed_items")
        let renamed = try await service.fetchDescriptor(named: "renamed_items")
        #expect(renamed.name == "renamed_items")
    }

    @Test
    func insertDefaultRowFillsRequiredEditableColumns() async throws {
        let url = try TestSupport.createFixture(named: "insert-default")
        let service = DatabaseService()
        try await service.open(url: url)

        let descriptor = try await service.fetchDescriptor(named: "tags")
        try await service.insertDefaultRow(into: descriptor)

        let refreshed = try await service.fetchChunk(
            query: TableQueryState(sort: SortState(columnName: "id", direction: .descending), limit: 1),
            descriptor: descriptor
        )

        #expect(refreshed.totalRowCount == 13)
        #expect(refreshed.rows.first?.values[1] == .text(""))
    }
}
