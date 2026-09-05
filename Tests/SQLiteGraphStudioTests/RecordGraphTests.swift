import XCTest
@testable import StudioCore

@MainActor
final class RecordGraphTests: XCTestCase {
    func testCyclesSelfLinksAndDistinctRelationshipsDeduplicateOnlyNodes() {
        let a = record(1), b = record(2)
        let model = RecordGraphModel()
        model.setRoot(a)
        model.add(page([a, b]), from: a, relationship: relation("parent"), direction: .outgoing)
        model.add(page([b]), from: a, relationship: relation("owner"), direction: .outgoing)
        model.add(page([a]), from: b, relationship: relation("parent"), direction: .outgoing)
        XCTAssertEqual(model.records.count, 2)
        XCTAssertEqual(model.graph.edges.count, 4)
        XCTAssertEqual(model.graph.edges.filter { $0.sourceID == $0.targetID }.count, 1)
    }

    func testHighDegreeExpansionIsBoundedAndExposesRemainder() {
        let root = record(0)
        let model = RecordGraphModel(limits: .init(nodes: 3, edges: 3, depth: 2, queries: 4))
        model.setRoot(root)
        model.add(page((1...20).map(record)), from: root, relationship: relation("parent"), direction: .incoming)
        XCTAssertEqual(model.records.count, 3)
        XCTAssertEqual(model.graph.edges.count, 2)
        XCTAssertTrue(model.branches.values.first!.hasMore)
        XCTAssertEqual(model.branches.values.first!.nextOffset, 2)
        XCTAssertNotNil(model.limitMessage)
    }

    func testCollapsePreservesSharedNodeAndPrunesUnreachableBranches() {
        let a = record(1), b = record(2), c = record(3)
        let model = RecordGraphModel()
        model.setRoot(a)
        let first = relation("first"), second = relation("second")
        model.add(page([b]), from: a, relationship: first, direction: .outgoing)
        model.add(page([b]), from: a, relationship: second, direction: .outgoing)
        model.add(page([c]), from: b, relationship: first, direction: .outgoing)
        model.collapse(.init(recordID: a.id, relationshipID: first.id, direction: .outgoing))
        XCTAssertEqual(model.records.count, 3)
        model.collapse(.init(recordID: a.id, relationshipID: second.id, direction: .outgoing))
        XCTAssertEqual(model.records.count, 1)
        XCTAssertTrue(model.branches.isEmpty)
    }

    func testDepthAndQueryBudgetsResetForNewRoot() {
        let a = record(1), b = record(2)
        let model = RecordGraphModel(limits: .init(nodes: 5, edges: 5, depth: 1, queries: 1))
        model.setRoot(a)
        XCTAssertTrue(model.beginExpansion(from: a))
        model.add(page([b]), from: a, relationship: relation("x"), direction: .outgoing)
        XCTAssertFalse(model.beginExpansion(from: b))
        model.setRoot(b)
        XCTAssertTrue(model.beginExpansion(from: b))
    }

    func testMappedEdgesKeepParallelEdgeRecordsAndDirection() {
        let a = record(1), b = record(2)
        let model = RecordGraphModel()
        model.setRoot(a)
        let connections = [
            RecordMappedConnection(edge: record(10), source: a, target: b, label: "first", isDirected: true),
            RecordMappedConnection(edge: record(11), source: a, target: b, label: "second", isDirected: false)
        ]
        let mapped = RecordMappedPage(connections: connections, hasMore: false, nextOffset: nil, messages: [], queryCount: 4)
        model.addMapped(mapped, from: a, mappingID: "mapping", direction: .outgoing)
        XCTAssertEqual(model.records.count, 2)
        XCTAssertEqual(model.graph.edges.count, 2)
        XCTAssertEqual(Set(model.graph.edges.map(\.sourceColumn)), ["first", "second"])
        XCTAssertEqual(model.undirectedEdgeIDs.count, 1)
    }

    private func record(_ value: Int) -> RecordSnapshot {
        let column = TableColumn(name: "key", declaredType: "INTEGER", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)
        let descriptor = TableDescriptor(name: "items", objectType: .table, columns: [column], primaryKeyColumns: ["key"], rowIdentityStrategy: .primaryKey, isWithoutRowID: false, isEditable: true)
        return try! RecordAccess.snapshot(descriptor: descriptor, columns: [QueryResultColumn(name: "key", typeLabel: "INTEGER")], values: [.integer(Int64(value))])
    }
    private func relation(_ name: String) -> RecordRelationship {
        let table = RecordTableID(schemaName: nil, objectName: "items")
        return RecordRelationship(id: name, sourceTable: table, targetTable: table, sourceColumns: ["key"], targetColumns: ["key"], sourceDescriptor: nil, targetDescriptor: nil)
    }
    private func page(_ records: [RecordSnapshot]) -> RecordPage {
        RecordPage(records: records, hasMore: false, nextOffset: nil, status: .loaded)
    }
}
