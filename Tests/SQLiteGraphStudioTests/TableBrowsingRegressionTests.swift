import Foundation
import GRDB
import Testing
@testable import StudioCore

struct TableBrowsingRegressionTests {
    static func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-browsing-\(UUID().uuidString).sqlite")
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE items(tenant INTEGER NOT NULL, id INTEGER NOT NULL, label TEXT, amount REAL, PRIMARY KEY(tenant,id)); WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1205) INSERT INTO items SELECT x%3,x,CASE WHEN x%5=0 THEN NULL ELSE 'same' END,x+0.5 FROM n")
        }
        return url
    }
    @Test func browsingDoesNotClaimAnExactCountBeforeCounting() async throws {
        let url = try Self.fixture()
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let chunk = try await service.fetchChunk(query: .init(limit: 2), descriptor: descriptor)
        #expect(chunk.rows.count == 2)
        #expect(chunk.totalRowCount == 3) // 2 known rows plus a navigation sentinel, not all 1205.
        await service.close()
    }
    @Test func boundedCellReadsStreamSlicesWithoutLoadingHugeTextOrBlobValues() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-bounded-cell-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "é🛰️", count: 50_000)
        let blob = Data(repeating: 0xA7, count: 8 * 1_024 * 1_024)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE cells(id INTEGER PRIMARY KEY, note TEXT, payload BLOB, nullable BLOB, empty_text TEXT, empty_blob BLOB, scalar INTEGER)")
            try db.execute(sql: "INSERT INTO cells VALUES (?, ?, ?, NULL, ?, ?, ?)", arguments: [1, text, blob, "", Data(), 42])
        }

        let service = DatabaseService()
        try await service.open(url: url, readOnly: true, includeRowCounts: false)
        let descriptor = try await service.fetchDescriptor(named: "cells")
        let query = TableQueryState(offset: 0, limit: 1)
        let textSlice = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                       columnName: "note", offset: 7, length: 12))
        let expectedScalars = Array(text.unicodeScalars)[7..<19]
        #expect(textSlice.value == .text(String(String.UnicodeScalarView(expectedScalars))))
        #expect(textSlice.characterCount == text.unicodeScalars.count)
        #expect(textSlice.byteCount == text.utf8.count)
        #expect(textSlice.returnedLength == 12)
        #expect(textSlice.hasMore)
        #expect(!textSlice.isComplete)

        let blobSlice = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                       columnName: "payload", offset: 100, length: 19))
        #expect(blobSlice.storageType == "blob")
        #expect(blobSlice.value == .blob(Data(repeating: 0xA7, count: 19)))
        #expect(blobSlice.byteCount == blob.count)
        #expect(blobSlice.characterCount == nil)
        #expect(blobSlice.returnedLength == 19)
        #expect(blobSlice.offsetUnit == "bytes")

        let pastBlobEnd = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                         columnName: "payload", offset: blob.count + 4, length: 9))
        #expect(pastBlobEnd.value == .blob(Data()))
        #expect(pastBlobEnd.isBinary)
        #expect(pastBlobEnd.byteCount == blob.count)
        #expect(!pastBlobEnd.hasMore)
        #expect(!pastBlobEnd.isComplete)

        let emptyText = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                      columnName: "empty_text", offset: 0, length: 16))
        #expect(emptyText.storageType == "text")
        #expect(emptyText.value == .text(""))
        #expect(emptyText.byteCount == 0)
        #expect(emptyText.characterCount == 0)
        #expect(emptyText.isComplete)

        let emptyBlob = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                      columnName: "empty_blob", offset: 0, length: 16))
        #expect(emptyBlob.value == .blob(Data()))
        #expect(emptyBlob.isBinary)
        #expect(emptyBlob.byteCount == 0)
        #expect(emptyBlob.isComplete)

        let nullValue = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                       columnName: "nullable", offset: 4, length: 16))
        #expect(nullValue.isNull)
        #expect(nullValue.value == .null)
        #expect(nullValue.byteCount == nil)
        #expect(nullValue.characterCount == nil)
        #expect(nullValue.isComplete)

        let scalar = try #require(try await service.readBoundedCell(query: query, descriptor: descriptor,
                                                                    columnName: "scalar", offset: 0, length: 16))
        #expect(scalar.storageType == "integer")
        #expect(scalar.value == .text("42"))
        #expect(scalar.isComplete)
        await #expect(throws: DatabaseUserError.self) {
            try await service.readBoundedCell(query: query, descriptor: descriptor,
                                              columnName: "payload", offset: -1, length: -999_999)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await service.readBoundedCell(query: query, descriptor: descriptor,
                                              columnName: "payload", offset: 0, length: 65_537)
        }
        await service.close()
    }

    @Test func fullCellActionsUseOneSnapshotAcrossSameLengthConcurrentUpdates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-cell-snapshot-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let originalText = String(repeating: "é", count: 140_000)
        let updatedText = String(repeating: "ø", count: 140_000)
        let originalBlob = Data(repeating: 0xA7, count: 280_000)
        let updatedBlob = Data(repeating: 0xB8, count: originalBlob.count)
        let finalBlob = Data(repeating: 0xC9, count: originalBlob.count)
        let writer = try DatabaseQueue(path: url.path)
        try await writer.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE cells(id INTEGER PRIMARY KEY, note TEXT, payload BLOB)")
            try db.execute(sql: "INSERT INTO cells VALUES (1, ?, ?)", arguments: [originalText, originalBlob])
        }

        let service = DatabaseService()
        try await service.open(url: url, includeRowCounts: false)
        let descriptor = try await service.fetchDescriptor(named: "cells")
        var query = TableQueryState(limit: 1)
        query.omitOversizedCells = true
        let page = try await service.fetchChunk(query: query, descriptor: descriptor)
        let row = try #require(page.rows.first)
        #expect(row.omittedColumnIndices == [1, 2])

        let textSlices = try await service.withBoundedCellReadSnapshot(
            query: query,
            descriptor: descriptor,
            columnName: "note",
            expectedRowIdentity: row.identity
        ) { reader in
            let first = try #require(try await reader.read(offset: 0))
            try await writer.write { db in
                try db.execute(sql: "UPDATE cells SET note = ?, payload = ? WHERE id = 1",
                               arguments: [updatedText, updatedBlob])
            }
            let middle = try #require(try await reader.read(offset: 4_096))
            let lastOffset = originalText.unicodeScalars.count - 1
            let last = try #require(try await reader.read(offset: lastOffset))
            return [first, middle, last]
        }
        #expect(textSlices.map(\.value) == [
            .text(String(repeating: "é", count: 4_096)),
            .text(String(repeating: "é", count: 4_096)),
            .text("é")
        ])
        #expect(textSlices.map(\.characterCount) == Array(repeating: originalText.unicodeScalars.count, count: 3))
        #expect(textSlices.map(\.byteCount) == Array(repeating: originalText.utf8.count, count: 3))

        let blobSlices = try await service.withBoundedCellReadSnapshot(
            query: query,
            descriptor: descriptor,
            columnName: "payload",
            expectedRowIdentity: row.identity
        ) { reader in
            let first = try #require(try await reader.read(offset: 0))
            try await writer.write { db in
                try db.execute(sql: "UPDATE cells SET payload = ? WHERE id = 1", arguments: [finalBlob])
            }
            let middle = try #require(try await reader.read(offset: 4_096))
            let last = try #require(try await reader.read(offset: originalBlob.count - 1))
            return [first, middle, last]
        }
        #expect(blobSlices.map(\.value) == [
            .blob(Data(repeating: 0xB8, count: 4_096)),
            .blob(Data(repeating: 0xB8, count: 4_096)),
            .blob(Data([0xB8]))
        ])
        #expect(blobSlices.map(\.byteCount) == Array(repeating: originalBlob.count, count: 3))

        let copiedText = try await service.withBoundedCellReadSnapshot(
            query: query, descriptor: descriptor, columnName: "note", expectedRowIdentity: row.identity
        ) { reader in
            try await BoundedCellOperations.collectForClipboard { offset, length in
                try await reader.read(offset: offset, length: length)
            }
        }
        #expect(copiedText == .text(updatedText))

        let copiedBlob = try await service.withBoundedCellReadSnapshot(
            query: query, descriptor: descriptor, columnName: "payload", expectedRowIdentity: row.identity
        ) { reader in
            try await BoundedCellOperations.collectForClipboard { offset, length in
                try await reader.read(offset: offset, length: length)
            }
        }
        #expect(copiedBlob == .binary(finalBlob))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textDestination = folder.appendingPathComponent("value.txt")
        let textBytes = try await service.withBoundedCellReadSnapshot(
            query: query, descriptor: descriptor, columnName: "note", expectedRowIdentity: row.identity
        ) { reader in
            try await BoundedCellOperations.saveToFile(at: textDestination) { offset, length in
                try await reader.read(offset: offset, length: length)
            }
        }
        #expect(textBytes == updatedText.utf8.count)
        #expect(try String(contentsOf: textDestination, encoding: .utf8) == updatedText)

        let blobDestination = folder.appendingPathComponent("value.bin")
        let blobBytes = try await service.withBoundedCellReadSnapshot(
            query: query, descriptor: descriptor, columnName: "payload", expectedRowIdentity: row.identity
        ) { reader in
            try await BoundedCellOperations.saveToFile(at: blobDestination) { offset, length in
                try await reader.read(offset: offset, length: length)
            }
        }
        #expect(blobBytes == finalBlob.count)
        #expect(try Data(contentsOf: blobDestination) == finalBlob)

        await service.close()
        try writer.close()
    }

    @Test func resultPagesRejectOversizedCellsBeforeMaterializingThem() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-page-budget-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try DatabaseQueue(path: url.path)
        try await fixture.write { db in
            try db.execute(sql: "CREATE TABLE large_cells(id INTEGER PRIMARY KEY, payload BLOB); INSERT INTO large_cells VALUES(1, zeroblob(300000))")
            try db.execute(sql: "CREATE TABLE record_sentinel(id INTEGER PRIMARY KEY, payload BLOB); INSERT INTO record_sentinel VALUES(1, x'01'), (2, zeroblob(300000))")
        }
        let service = DatabaseService()
        try await service.open(url: url, readOnly: true, includeRowCounts: false)
        let descriptor = try await service.fetchDescriptor(named: "large_cells")
        await #expect(throws: DatabaseUserError.self) {
            try await service.fetchChunk(query: .init(limit: 1), descriptor: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await service.fetchRecords(descriptor: descriptor,
                                           predicates: [IdentityComponent(columnName: "id", value: .integer(1))])
        }
        let sentinelDescriptor = try await service.fetchDescriptor(named: "record_sentinel")
        let tablePage = try await service.fetchChunk(query: .init(limit: 1), descriptor: sentinelDescriptor)
        #expect(tablePage.rows.count == 1)
        #expect(tablePage.hasMore)
        let recordPage = try await service.fetchRecords(descriptor: sentinelDescriptor, predicates: [], limit: 1)
        #expect(recordPage.records.count == 1)
        #expect(recordPage.hasMore)
        var projected = TableQueryState(limit: 1)
        projected.projectedColumns = ["id"]
        let safePage = try await service.fetchChunk(query: projected, descriptor: descriptor)
        #expect(safePage.rows.first?.values == [.integer(1)])
        await #expect(throws: DatabaseUserError.self) {
            try await service.executeReadOnlyQuery(sql: "SELECT randomblob(300000)", rowLimit: 1)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await service.executeReadOnlyQuery(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<150) SELECT zeroblob(65536) FROM n", rowLimit: 200)
        }
        await service.close()
    }
    @Test func typedFiltersUseEqualityRangeAndNullSemantics() async throws {
        let url = try Self.fixture()
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let equals = try await service.fetchChunk(query: .init(columnFilters: [.init(columnName: "id", value: "2", comparison: .equal)]), descriptor: descriptor)
        #expect(equals.rows.count == 1)
        let range = try await service.fetchChunk(query: .init(columnFilters: [.init(columnName: "id", value: "10", comparison: .between, upperValue: "12")]), descriptor: descriptor)
        #expect(Set(range.rows.map { $0.values[1] }) == Set([.integer(10), .integer(11), .integer(12)]))
        let nulls = try await service.fetchChunk(query: .init(columnFilters: [.init(columnName: "label", comparison: .isNull)], limit: 10), descriptor: descriptor)
        #expect(nulls.rows.count == 10)
        #expect(nulls.rows.allSatisfy { $0.values[2] == .null })
        await service.close()
    }

    @Test func compositeCursorPagesMatchOrderedQueryWithDuplicateAndNullSortValues() async throws {
        let url = try Self.fixture()
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "items")
        var query = TableQueryState(sort: .init(columnName: "label", direction: .descending), limit: 37)
        var values: [[SQLiteValue]] = []
        for _ in 0..<40 {
            let page = try await service.fetchChunk(query: query, descriptor: descriptor)
            values += page.rows.map(\.values)
            guard page.rows.count == 37, let last = page.rows.last else { break }
            query.offset = values.count
            query.after = .init(values: Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), last.values)))
        }
        let expected = try await service.executeReadOnlyQuery(sql: "SELECT * FROM items ORDER BY label DESC NULLS LAST, tenant ASC, id ASC", rowLimit: 2000)
        #expect(values == expected.rows.map(\.values))
        #expect(values.count == 1205)
        #expect(Set(values.map { $0[1] }).count == 1205)
        #expect(try await service.countRows(query: query, descriptor: descriptor) == 1205)
        await service.close()
    }
    @Test func textContainsEscapesWildcardsAndInvalidTypedInputIsRejected() async throws {
        let url = try Self.fixture()
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let wildcard = try await service.fetchChunk(query: .init(columnFilters: [.init(columnName: "label", value: "%")]), descriptor: descriptor)
        #expect(wildcard.rows.isEmpty)
        await #expect(throws: DatabaseUserError.self) {
            try await service.fetchChunk(query: .init(columnFilters: [.init(columnName: "id", value: "2 OR 1=1", comparison: .equal)]), descriptor: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await service.fetchChunk(query: .init(columnFilters: [.init(columnName: "missing", value: "x")]), descriptor: descriptor)
        }
        await service.close()
    }

    @Test func postgresTypeCastsRejectSQLAndPreserveQuotedNames() throws {
        #expect(try PostgresTableQueryBuilder.postgresCast(#""Custom Schema"."CaseType"[]"#) == #""Custom Schema"."CaseType"[]"#)
        #expect(try PostgresTableQueryBuilder.postgresCast("numeric(10,-2)[]") == "numeric[]")
        #expect(try PostgresTableQueryBuilder.postgresCast("character(3)[]") == "pg_catalog.bpchar[]")
        #expect(try PostgresTableQueryBuilder.postgresCast("bit(3)") == "pg_catalog.bit")
        #expect(try PostgresTableQueryBuilder.postgresCast(#""Type(3)""#) == #""Type(3)""#)
        #expect(try PostgresTableQueryBuilder.postgresCast("money[]") == "numeric[]::money[]")
        for invalid in ["text; DROP TABLE x", "text) OR TRUE --", "text /* comment */", "text\n; SELECT 1"] {
            #expect(throws: DatabaseUserError.self) { try PostgresTableQueryBuilder.postgresCast(invalid) }
        }
    }
    @Test func cursorOffsetsAreNotCurrentCountEvidence() {
        var query = TableQueryState(offset: 300, limit: 50)
        query.after = .init(values: ["id": .integer(300)])
        #expect(TableCountState.forPage(query: query, rowCount: 10, hasMore: false, exactCount: nil) == .unknown)
        #expect(TableCountState.forPage(query: query, rowCount: 50, hasMore: true, exactCount: nil) == .unknown)
        #expect(TableCountState.forPage(query: query, rowCount: 10, hasMore: false, exactCount: 500) == .exact(500))
    }
    @Test func emptyPastEndIsUnknownAndStaleCountCannotEnableNext() async throws {
        let url = try Self.fixture()
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let empty = try await service.fetchChunk(query: .init(offset: 2000, limit: 2), descriptor: descriptor)
        #expect(empty.countState == .unknown)
        #expect(!empty.hasMore)
        var stale = TableQueryState(offset: 1204, limit: 10)
        stale.cachedExactCount = 5000
        let end = try await service.fetchChunk(query: stale, descriptor: descriptor)
        #expect(end.rows.count == 1)
        #expect(!end.hasMore)
        await service.close()
    }
    @Test func binaryKeysAndExpressionIndexMetadataRemainLossless() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-binary-\(UUID().uuidString).sqlite")
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE bin(id BLOB PRIMARY KEY NOT NULL, label TEXT); INSERT INTO bin VALUES(x'00','a'),(x'01','b'),(x'ff','c'); CREATE UNIQUE INDEX expression_key ON bin(label, lower(label))")
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "bin")
        #expect(descriptor.indexes.first { $0.name == "expression_key" }?.columns == ["label", ""])
        var query = TableQueryState(limit: 1)
        let first = try await service.fetchChunk(query: query, descriptor: descriptor)
        let row = try #require(first.rows.first)
        query.offset = 1
        var values = Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), row.values))
        if case .rowID(let id) = row.identity { values["_rowid_"] = .integer(id) }
        query.after = .init(values: values)
        let second = try await service.fetchChunk(query: query, descriptor: descriptor)
        #expect(second.rows.first?.values[0] == .blob(Data([1])))
        await service.close()
    }

    @Test func sqliteCursorsPreserveStoredTypesAcrossColumnAffinities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-mixed-cursors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let fixture = try DatabaseQueue(path: url.path)
        try await fixture.write { db in
            try db.execute(sql: """
                CREATE TABLE mixed(id INTEGER PRIMARY KEY, integer_value INTEGER, real_value REAL, numeric_value NUMERIC, boolean_value BOOLEAN, untyped);
                INSERT INTO mixed VALUES
                    (1,1,1,1,1,1),
                    (2,1.5,1.5,1.5,1.5,1.5),
                    (3,'unknown','unknown','unknown','unknown','1'),
                    (4,2,2,2,2,2),
                    (5,'later','later','later','later','abc'),
                    (6,x'01',x'01',x'01',x'01',x'01');
                """)
        }
        let service = DatabaseService()
        try await service.open(url: url)
        do {
            let descriptor = try await service.fetchDescriptor(named: "mixed")
            for column in ["integer_value", "real_value", "numeric_value", "boolean_value", "untyped"] {
                for direction in [SortDirection.ascending, .descending] {
                    var query = TableQueryState(sort: .init(columnName: column, direction: direction), limit: 1)
                    var values: [[SQLiteValue]] = []
                    for _ in 0..<10 {
                        let page = try await service.fetchChunk(query: query, descriptor: descriptor)
                        values += page.rows.map(\.values)
                        guard page.hasMore, let last = page.rows.last else { break }
                        query.offset = values.count
                        query.after = .init(values: Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), last.values)))
                    }
                    let expected = try await service.executeReadOnlyQuery(sql: "SELECT * FROM mixed ORDER BY \(quoteIdentifier(column)) \(direction.sqlKeyword) NULLS LAST, id ASC")
                    #expect(values == expected.rows.map(\.values), "Cursor changed values for \(column) \(direction)")
                    #expect(values.count == 6)
                }
            }
            await service.close()
        } catch {
            await service.close()
            throw error
        }
    }

}
