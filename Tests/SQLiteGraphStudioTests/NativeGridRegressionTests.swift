import AppKit
import GRDB
import Testing
@testable import StudioCore

@MainActor
struct NativeGridRegressionTests {
    @Test func duplicateGridColumnsDisplayAndCopyDistinctValuesAfterReorder() throws {
        let result = QueryResult(columns: ["id", "id", "id_2"].map { .init(name: $0, typeLabel: "INTEGER") }, rows: [.init(id: 0, values: [.integer(1), .integer(2), .integer(3)])], isTruncated: false, rowLimit: 500)
        let coordinator = QueryResultsGridRepresentable.Coordinator(result: result, columnDescription: { _ in nil }, inspectRow: { _ in })
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? NSTableView)
        coordinator.update(result: result, columnDescription: { _ in nil }, scrollView: scroll, inspectRow: { _ in })
        #expect(table.tableColumns.map(\.identifier.rawValue) == ["0", "1", "2"])
        #expect(table.tableColumns.map(\.title) == ["id", "id", "id_2"])
        func texts(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts) }
        for index in 0..<3 {
            let cell = try #require(coordinator.tableView(table, viewFor: table.tableColumns[index], row: 0))
            #expect(texts(cell).contains(String(index + 1)))
        }
        table.moveColumn(1, toColumn: 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(coordinator.selectionText() == "id\tid\tid_2\n2\t1\t3")
    }

    @Test func nextPageMovesViewportAndDoesNotReloadPreviousPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-grid-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY); WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<150) INSERT INTO items SELECT x FROM n")
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let tab = TableTabModel(descriptor: descriptor, databaseService: service, state: .init(limit: 50))
        await tab.reload()
        let coordinator = TableGridRepresentable.Coordinator(tab: tab, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, inspectRow: { _ in })
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        coordinator.update(tab: tab, revision: tab.revision, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, scrollView: scroll, inspectRow: { _ in })
        tab.nextPage()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while tab.chunk.offset != 50 {
            guard ContinuousClock.now < deadline else { Issue.record("Next page did not load"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.update(tab: tab, revision: tab.revision, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, scrollView: scroll, inspectRow: { _ in })
        try await Task.sleep(for: .milliseconds(30))
        #expect(tab.chunk.offset == 50)
        #expect(tab.row(at: 50)?.values == [.integer(51)])
        #expect(scroll.contentView.bounds.origin.y >= 50 * 44)
        await service.close()
    }
}
