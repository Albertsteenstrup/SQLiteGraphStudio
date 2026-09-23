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
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 340)
        scroll.layoutSubtreeIfNeeded()
        let header = try #require(table.headerView)
        #expect(!scroll.contentView.frame.intersects(header.convert(header.bounds, to: scroll)))
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
        scroll.layoutSubtreeIfNeeded()
        if let grid = scroll.documentView as? NSTableView, let header = grid.headerView {
            #expect(!scroll.contentView.frame.intersects(header.convert(header.bounds, to: scroll)))
        }
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

    @Test func switchingLoadedTabsWithEqualRevisionsRefreshesNativeRows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-grid-tabs-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE first_items(id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE second_items(id INTEGER PRIMARY KEY, name TEXT);
                INSERT INTO first_items VALUES (1, 'First table record');
                INSERT INTO second_items VALUES (2, 'Second table record'), (3, 'Another second record');
                """)
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let firstDescriptor = try await service.fetchDescriptor(named: "first_items")
        let secondDescriptor = try await service.fetchDescriptor(named: "second_items")
        let first = TableTabModel(descriptor: firstDescriptor, databaseService: service)
        let second = TableTabModel(descriptor: secondDescriptor, databaseService: service)
        await first.reload()
        await second.reload()
        #expect(first.revision == second.revision)
        let coordinator = TableGridRepresentable.Coordinator(tab: first, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, inspectRow: { _ in })
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let table = try #require(scroll.documentView as? NSTableView)
        coordinator.update(tab: first, revision: first.revision, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, scrollView: scroll, inspectRow: { _ in })
        #expect(table.numberOfRows == 1)
        func texts(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts) }
        let firstCell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
        #expect(texts(firstCell).contains("First table record"))

        coordinator.update(tab: second, revision: second.revision, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, scrollView: scroll, inspectRow: { _ in })

        // Inspect Record now reads `second`; the retained native grid must show it too.
        #expect(table.numberOfRows == 2)
        let secondCell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
        #expect(texts(secondCell).contains("Second table record"))
        await service.close()
    }

    @Test func oversizedCellsStayVisibleAsSlicePromptsAndCannotBeEdited() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-grid-large-cell-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try DatabaseQueue(path: url.path)
        let oversizedText = String(repeating: "x", count: 300_000)
        let oversizedBlob = Data(repeating: 0xA7, count: 300_000)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY, payload TEXT, binary_payload BLOB, note TEXT)")
            try db.execute(sql: "INSERT INTO items VALUES (?, ?, ?, ?)", arguments: [1, oversizedText, oversizedBlob, "visible note"])
        }

        let service = DatabaseService()
        try await service.open(url: url, includeRowCounts: false)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let tab = TableTabModel(descriptor: descriptor, databaseService: service, state: .init(limit: 5))
        await tab.reload()

        #expect(tab.inlineErrorMessage == nil)
        #expect(!tab.queryState.omitOversizedCells)
        #expect(tab.row(at: 0)?.omittedColumnIndices == [1, 2])
        #expect(tab.displayedValue(row: 0, column: 0) == "1")
        #expect(tab.displayedValue(row: 0, column: 1) == "Large value — inspect in slices")
        #expect(tab.displayedValue(row: 0, column: 2) == "Large value — inspect in slices")
        #expect(tab.displayedValue(row: 0, column: 3) == "visible note")
        #expect(tab.canEditCell(row: 0, column: 1) == false)
        #expect(tab.canEditCell(row: 0, column: 2) == false)
        #expect(tab.canEditCell(row: 0, column: 3))
        await #expect(throws: SQLiteUserError.self) {
            try await service.serializeTableRows(descriptor: descriptor, rows: tab.chunk.rows, format: .csv)
        }

        var requestedSlice: (Int, String)?
        let coordinator = TableGridRepresentable.Coordinator(
            tab: tab,
            columnDescription: { _ in nil },
            requestColumnDrop: { _ in },
            inspectRow: { _ in },
            inspectCellSlice: { requestedSlice = ($0, $1) }
        )
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? NSTableView)
        coordinator.update(
            tab: tab,
            revision: tab.revision,
            columnDescription: { _ in nil },
            requestColumnDrop: { _ in },
            scrollView: scroll,
            inspectRow: { _ in },
            inspectCellSlice: { requestedSlice = ($0, $1) }
        )
        func texts(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts) }
        let payloadCell = try #require(coordinator.tableView(table, viewFor: table.tableColumns[1], row: 0))
        #expect(texts(payloadCell).contains("Large value — inspect in slices"))

        let payloadMenu = coordinator.makeContextMenu(row: 0, columnName: "payload")
        let inspectRecord = try #require(payloadMenu.items.first { $0.title == "Inspect Record…" })
        let inspectSlice = try #require(payloadMenu.items.first { $0.title == "Inspect Cell Slice…" })
        #expect(!inspectRecord.isEnabled)
        #expect(inspectSlice.isEnabled)
        coordinator.contextMenuInspectCellSlice(inspectSlice)
        #expect(requestedSlice?.0 == 0)
        #expect(requestedSlice?.1 == "payload")

        let visibleCellMenu = coordinator.makeContextMenu(row: 0, columnName: "note")
        #expect(visibleCellMenu.items.first { $0.title == "Inspect Cell Slice…" } == nil)

        let session = AppSession(databaseService: service, userDefaults: UserDefaults(suiteName: "sgs-grid-slice-\(UUID())")!)
        session.openTabs = [tab]
        await session.inspectCellSlice(in: tab, row: 0, columnName: "payload").value
        let textSnapshot = try #require(session.records.current)
        #expect(textSnapshot.partialCellRead?.isComplete == false)
        #expect(textSnapshot.partialCellRead?.hasMore == true)
        #expect(textSnapshot.columns.map(\.name) == ["payload"])
        #expect(textSnapshot.values == [.text(String(repeating: "x", count: 4_096))])
        #expect(textSnapshot.identity == nil)
        #expect(session.records.originLabel == "items · row 1 · payload")
        let firstNavigation = try #require(session.gridCellSliceNavigation(for: textSnapshot))
        #expect(!firstNavigation.canReadPrevious)
        #expect(firstNavigation.canReadNext)
        let searchSlice = try await session.readGridCellSlice(for: textSnapshot, offset: 8_192)
        #expect(searchSlice.offset == 8_192)
        #expect(searchSlice.returnedLength == 4_096)
        #expect(session.records.current?.id == textSnapshot.id)
        #expect(session.gridCellSliceNavigation(for: textSnapshot)?.canReadPrevious == false)

        await session.navigateGridCellSlice(for: textSnapshot, direction: .next).value
        let secondSlice = try #require(session.records.current)
        #expect(secondSlice.partialCellRead?.offset == 4_096)
        #expect(secondSlice.partialCellRead?.returnedLength == 4_096)
        #expect(secondSlice.partialCellRead?.hasMore == true)
        #expect(secondSlice.values == [.text(String(repeating: "x", count: 4_096))])
        let secondNavigation = try #require(session.gridCellSliceNavigation(for: secondSlice))
        #expect(secondNavigation.canReadPrevious)
        #expect(secondNavigation.canReadNext)

        await session.navigateGridCellSlice(for: secondSlice, direction: .previous).value
        let returnedSlice = try #require(session.records.current)
        #expect(returnedSlice.partialCellRead?.offset == 0)
        #expect(returnedSlice.values == [.text(String(repeating: "x", count: 4_096))])
        await session.showGridCellSlice(for: returnedSlice, offset: 12_288).value
        let jumpedSlice = try #require(session.records.current)
        #expect(jumpedSlice.partialCellRead?.offset == 12_288)
        await #expect(throws: SQLiteUserError.self) {
            try await session.readGridCellSlice(for: returnedSlice, offset: 0)
        }

        let agentSlice = RecordSnapshot(
            descriptor: descriptor,
            columns: [QueryResultColumn(name: "payload", typeLabel: "TEXT")],
            values: returnedSlice.values,
            identity: nil,
            label: "payload",
            partialCellRead: returnedSlice.partialCellRead
        )
        session.records.open(agentSlice)
        #expect(session.gridCellSliceNavigation(for: agentSlice) == nil)

        await session.inspectCellSlice(in: tab, row: 0, columnName: "binary_payload").value
        let blobSnapshot = try #require(session.records.current)
        #expect(blobSnapshot.partialCellRead?.isBinary == true)
        #expect(blobSnapshot.partialCellRead?.returnedLength == 4_096)
        #expect(blobSnapshot.values == [.blob(Data(repeating: 0xA7, count: 4_096))])
        #expect(session.gridCellSliceNavigation(for: blobSnapshot)?.canReadNext == true)
        await tab.reload()
        #expect(session.gridCellSliceNavigation(for: blobSnapshot) == nil)

        tab.commitEdit(row: 0, columnName: "payload", rawValue: "replacement")
        #expect(tab.inlineErrorMessage == "Large values are read-only in the grid. Inspect them in slices.")
        tab.cloneRow(at: 0)
        #expect(tab.inlineErrorMessage == "This row contains large values omitted from the grid and cannot be cloned from this page.")
        await service.close()
    }

    @Test func externalInsertBeforeLoadedRowFailsClosedForCellSlice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-grid-row-shift-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try DatabaseQueue(path: url.path)
        let oversizedText = String(repeating: "x", count: 300_000)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY, payload TEXT)")
            try db.execute(sql: "INSERT INTO items VALUES (10, 'first'), (20, ?), (30, 'last')", arguments: [oversizedText])
        }

        let service = DatabaseService()
        try await service.open(url: url, includeRowCounts: false)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let tab = TableTabModel(descriptor: descriptor, databaseService: service, state: .init(offset: 1, limit: 1))
        await tab.reload()
        let loadedRevision = tab.revision
        #expect(tab.row(at: 1)?.values.first == .integer(20))
        #expect(tab.row(at: 1)?.omittedColumnIndices == [1])

        // The external write shifts absolute offset 1 from key 20 to key 15,
        // while the open table tab keeps its original rows and revision.
        try await db.write { db in
            try db.execute(sql: "INSERT INTO items VALUES (15, 'inserted ahead of the selected row')")
        }
        #expect(tab.revision == loadedRevision)

        let session = AppSession(databaseService: service, userDefaults: UserDefaults(suiteName: "sgs-grid-row-shift-\(UUID())")!)
        session.openTabs = [tab]
        await session.inspectCellSlice(in: tab, row: 1, columnName: "payload").value

        #expect(session.records.current == nil)
        #expect(session.presentedError?.message == "The selected cell is no longer available.")
        #expect(tab.revision == loadedRevision)

        // Offset-only callers keep their existing behavior; the stale native
        // grid read above carries the expected identity and therefore rejects it.
        let offsetRead = try #require(try await service.readBoundedCell(
            query: TableQueryState(offset: 1, limit: 1),
            descriptor: descriptor,
            columnName: "payload"
        ))
        #expect(offsetRead.value == .text("inserted ahead of the selected row"))
        await service.close()
    }
}
