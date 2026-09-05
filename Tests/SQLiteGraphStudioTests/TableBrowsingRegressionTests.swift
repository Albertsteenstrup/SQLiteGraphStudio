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

}
