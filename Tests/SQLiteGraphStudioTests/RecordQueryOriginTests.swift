import XCTest
@testable import StudioCore

final class RecordQueryOriginTests: XCTestCase {
    func testOnlyExactDirectTableQueriesEstablishOrigin() {
        let table = descriptor("People")
        let result = QueryResult(columns: [.init(name: "key", typeLabel: "INTEGER")], rows: [], isTruncated: false, rowLimit: 50)
        let catalog = CatalogSnapshot(descriptors: [table], graph: .empty)
        XCTAssertEqual(RecordQueryOrigin.descriptor(executedSQL: "select * from \"public\".\"People\" LIMIT 50;", result: result, catalog: catalog), table)
        XCTAssertNil(RecordQueryOrigin.descriptor(executedSQL: "SELECT * FROM \"public\".\"people\"", result: result, catalog: catalog))
        XCTAssertNil(RecordQueryOrigin.descriptor(executedSQL: "SELECT p.* FROM \"public\".\"People\" p JOIN other o ON p.key=o.key", result: result, catalog: catalog))
        XCTAssertNil(RecordQueryOrigin.descriptor(executedSQL: "SELECT key + 1 AS key FROM \"public\".\"People\"", result: result, catalog: catalog))
        XCTAssertNil(RecordQueryOrigin.descriptor(executedSQL: nil, result: result, catalog: catalog))
        let mismatch = QueryResult(columns: [.init(name: "other", typeLabel: "INTEGER")], rows: [], isTruncated: false, rowLimit: 50)
        XCTAssertNil(RecordQueryOrigin.descriptor(executedSQL: "SELECT * FROM \"public\".\"People\"", result: mismatch, catalog: catalog))
    }
    private func descriptor(_ name: String) -> TableDescriptor {
        .init(name: "public." + name, objectType: .table, columns: [.init(name: "key", declaredType: "INTEGER", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)], primaryKeyColumns: ["key"], rowIdentityStrategy: .primaryKey, isWithoutRowID: false, isEditable: false, schemaName: "public", objectName: name)
    }
}
