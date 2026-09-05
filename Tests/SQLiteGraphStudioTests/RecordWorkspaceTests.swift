import XCTest
@testable import StudioCore

@MainActor
final class RecordWorkspaceTests: XCTestCase {
    func testBackForwardIncludesOriginAndPreservesLoadedSnapshot() throws {
        let workspace = RecordWorkspace { _, _, _, _, _ in .init(records: [], hasMore: false, nextOffset: nil, status: .loaded) }
        let a = try snapshot("A"), b = try snapshot("B")
        workspace.open(a)
        workspace.navigate(b)
        workspace.back()
        XCTAssertEqual(workspace.current?.values, a.values)
        workspace.back()
        XCTAssertNil(workspace.current)
        XCTAssertFalse(workspace.isPresented)
        workspace.forward()
        XCTAssertEqual(workspace.current?.values, a.values)
        workspace.forward()
        XCTAssertEqual(workspace.current?.values, b.values)
    }

    func testDatabaseResetAndNavigationDiscardLateResponses() async throws {
        let workspace = RecordWorkspace { _, _, _, _, _ in
            try? await Task.sleep(for: .milliseconds(60)) // deliberately ignores cancellation
            return .init(records: [], hasMore: false, nextOffset: nil, status: .missingReference)
        }
        let a = try snapshot("A")
        let table = RecordTableID(schemaName: nil, objectName: "items")
        let relation = RecordRelationship(id: "fk", sourceTable: table, targetTable: table, sourceColumns: ["key"], targetColumns: ["key"], sourceDescriptor: nil, targetDescriptor: nil)
        workspace.open(a)
        let request = workspace.load(relation, direction: .outgoing)
        workspace.navigate(try snapshot("B"))
        await request?.value
        XCTAssertTrue(workspace.pages.isEmpty)
        let second = workspace.load(relation, direction: .outgoing)
        workspace.reset()
        await second?.value
        XCTAssertNil(workspace.current)
        XCTAssertTrue(workspace.pages.isEmpty)
        XCTAssertTrue(workspace.errors.isEmpty)
    }

    func testCollapseInvalidatesPendingExpansionSoBranchStaysCollapsed() async throws {
        let column = TableColumn(name: "key", declaredType: "INTEGER", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)
        let descriptor = TableDescriptor(name: "items", objectType: .table, columns: [column], primaryKeyColumns: ["key"], rowIdentityStrategy: .primaryKey, isWithoutRowID: false, isEditable: true)
        let a = try RecordAccess.snapshot(descriptor: descriptor, columns: [.init(name: "key", typeLabel: "INTEGER")], values: [.integer(1)])
        let b = try RecordAccess.snapshot(descriptor: descriptor, columns: [.init(name: "key", typeLabel: "INTEGER")], values: [.integer(2)])
        let page = RecordPage(records: [b], hasMore: true, nextOffset: 1, status: .loaded)
        let workspace = RecordWorkspace { _, _, _, _, _ in
            try? await Task.sleep(for: .milliseconds(60))
            return page
        }
        let table = RecordTableID(descriptor: descriptor)
        let relation = RecordRelationship(id: "fk", sourceTable: table, targetTable: table, sourceColumns: ["key"], targetColumns: ["key"], sourceDescriptor: descriptor, targetDescriptor: descriptor)
        workspace.open(a); workspace.showConnections()
        workspace.recordGraph.add(page, from: a, relationship: relation, direction: .outgoing)
        let request = workspace.load(relation, direction: .outgoing, offset: 1, intoGraph: true)
        let key = try XCTUnwrap(workspace.key(relation, .outgoing))
        workspace.collapseBranch(key)
        await request?.value
        XCTAssertTrue(workspace.recordGraph.branches.isEmpty)
        XCTAssertEqual(workspace.recordGraph.records.count, 1)
        XCTAssertTrue(workspace.loading.isEmpty)
    }

    func testValuePresentationDistinguishesNullEmptyAndPreservesRawJSON() async {
        XCTAssertEqual(RecordValuePresentation.raw(.null), "NULL")
        XCTAssertEqual(RecordValuePresentation.raw(.text("")), "")
        XCTAssertEqual(RecordValuePresentation.summary(.text("")), "Empty text")
        let raw = "{\"n\":123456789012345678901234567890,\"s\":\"x\"}"
        XCTAssertEqual(RecordValuePresentation.raw(.json(raw)), raw)
        let formatted = await RecordValuePresentation.formattedJSON(raw)
        XCTAssertTrue(formatted.contains("123456789012345678901234567890"))
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertEqual(RecordValuePresentation.raw(.blob(Data([0, 255]))), "00ff")
    }

    private func snapshot(_ label: String) throws -> RecordSnapshot {
        try RecordAccess.snapshot(descriptor: nil, columns: [.init(name: "value", typeLabel: "TEXT")], values: [.text(label)])
    }
}
