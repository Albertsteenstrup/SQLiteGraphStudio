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

        let authorProfiles = try #require(descriptors["author_profiles"])
        #expect(authorProfiles.objectType == .view)
        #expect(!authorProfiles.isEditable)
        #expect(authorProfiles.rowIdentityStrategy == .readOnly)

        let syncMarkers = try #require(descriptors["sync_markers"])
        #expect(syncMarkers.isWithoutRowID)
        #expect(syncMarkers.isEditable)
        #expect(syncMarkers.rowIdentityStrategy == .primaryKey)
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
}
