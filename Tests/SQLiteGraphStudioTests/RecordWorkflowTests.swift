import XCTest
@preconcurrency import GRDB
@testable import StudioCore

@MainActor
final class RecordWorkflowTests: XCTestCase {
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
