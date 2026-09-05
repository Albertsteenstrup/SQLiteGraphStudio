import XCTest
@preconcurrency import GRDB
@testable import StudioCore

@MainActor
final class RecordWorkflowTests: XCTestCase {
    func testChangingMappingDefinitionInvalidatesExistingExploration() throws {
        let column = TableColumn(name: "key", declaredType: "INTEGER", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)
        let table = TableDescriptor(name: "items", objectType: .table, columns: [column], primaryKeyColumns: ["key"], rowIdentityStrategy: .primaryKey, isWithoutRowID: false, isEditable: true)
        let id = RecordTableID(descriptor: table)
        var mapping = RecordGraphMapping(id: "same-id", name: "Network", nodeTable: id, nodeIDColumns: ["key"], edgeTable: id, sourceColumns: ["key"], targetColumns: ["key"])
        let session = AppSession()
        session.records.catalog = CatalogSnapshot(descriptors: [table], graph: .empty)
        session.configureRecordMappings(SchemaSidecar(recordGraphMappings: [mapping]))
        let record = try RecordAccess.snapshot(descriptor: table, columns: [.init(name: "key", typeLabel: "INTEGER")], values: [.integer(1)])
        session.records.open(record); session.records.showConnections()
        session.configureRecordMappings(SchemaSidecar(recordGraphMappings: [mapping]))
        XCTAssertEqual(session.records.current, record)
        mapping.nodeScope = [.init(column: "key", value: .integer(2))]
        session.configureRecordMappings(SchemaSidecar(recordGraphMappings: [mapping]))
        XCTAssertNil(session.records.current)
        XCTAssertTrue(session.records.recordGraph.records.isEmpty)
        XCTAssertFalse(session.records.isPresented)
    }

    func testExecutedQueryOriginEnablesOnlyProvenNavigation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("record-query-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE people(key INTEGER PRIMARY KEY,name TEXT); INSERT INTO people VALUES(1,'Ada')")
        }
        let service = DatabaseService()
        let session = AppSession(databaseService: service)
        await session.openDatabase(url: url)
        let sql = "SELECT * FROM people"
        let result = try await service.executeReadOnlyQuery(sql: sql)
        var query = QueryDocument(title: "People", sqlText: sql, result: result, executedSQL: sql)
        query.sqlText = "SELECT * FROM people JOIN people other USING(key)"
        let row = try XCTUnwrap(result.rows.first)
        session.inspectQueryRecord(result: query.result, row: row, executedSQL: query.executedSQL)
        XCTAssertEqual(session.records.current?.table?.objectName, "people")
        XCTAssertNotNil(session.records.current?.identity)
        session.records.showConnections()
        XCTAssertEqual(session.records.recordGraph.records.count, 1)
        session.records.back()
        XCTAssertFalse(session.records.isPresented)
        XCTAssertEqual(query.sqlText, "SELECT * FROM people JOIN people other USING(key)")
        session.inspectQueryRecord(result: result, row: row, executedSQL: query.sqlText)
        XCTAssertNil(session.records.current?.identity)
        XCTAssertNil(session.records.current?.table)
        XCTAssertEqual(session.records.current?.values, row.values)
        session.closeDatabase()
    }

    func testTableInspectorRelatedBackGraphAndDatabaseReset() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("record-workflow-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE people(key INTEGER PRIMARY KEY,name TEXT); CREATE TABLE notes(key INTEGER PRIMARY KEY,person INTEGER REFERENCES people(key)); INSERT INTO people VALUES (1,'Ada'); INSERT INTO notes VALUES (2,1)")
        }
        let service = DatabaseService()
        let session = AppSession(databaseService: service)
        await session.openDatabase(url: url)
        let tab = try XCTUnwrap(session.openTable(named: "notes", autoLoad: false))
        await tab.reload()
        let query = tab.queryState
        session.inspectRecord(in: tab, row: 0)
        let original = try XCTUnwrap(session.records.current)
        let fk = try XCTUnwrap(session.records.relationships.first)
        await session.records.load(fk, direction: .outgoing)?.value
        let key = try XCTUnwrap(session.records.key(fk, .outgoing))
        let related = try XCTUnwrap(session.records.pages[key]?.records.first)
        session.records.navigate(related)
        session.records.back()
        XCTAssertEqual(session.records.current, original)
        session.records.showConnections()
        await session.records.load(fk, direction: .outgoing, intoGraph: true)?.value
        XCTAssertEqual(session.records.recordGraph.records.count, 2)
        session.records.navigate(related)
        XCTAssertEqual(session.records.current?.label, "Ada")
        session.records.back(); session.records.back()
        XCTAssertFalse(session.records.isPresented)
        XCTAssertEqual(tab.queryState, query)
        XCTAssertEqual(session.activeTabID, tab.id)
        session.closeDatabase()
        XCTAssertNil(session.records.current)
        XCTAssertTrue(session.records.recordGraph.records.isEmpty)
    }
}
