import AppKit
import Foundation
import GRDB
import Testing
@testable import StudioCore

@MainActor
struct ReportedUXRegressionTests {
    @Test func longHeaderCopiesOwnTheirSwiftStorage() throws {
        // NSCell is copied internally while AppKit draws/animates headers. Short
        // inline strings conceal the double-release seen with PostgreSQL types.
        for index in 0..<500 {
            let title = "research_public_query_identity_\(index)"
            let cell: MetadataHeaderCell = autoreleasepool {
                let source = MetadataHeaderCell(title: title, subtitle: String(repeating: "TIMESTAMP WITH TIME ZONE ", count: 8))
                source.isSortActive = true
                source.hasDescription = true
                source.hasFilter = true
                return source.copy() as! MetadataHeaderCell
            }
            #expect(cell.stringValue == title)
            #expect(cell.isSortActive && cell.hasDescription && cell.hasFilter)
            autoreleasepool {
                let image = NSImage(size: NSSize(width: 320, height: 58))
                image.lockFocus()
                cell.draw(withFrame: NSRect(x: 0, y: 0, width: 320, height: 58), in: NSView())
                image.unlockFocus()
            }
        }
    }

    @Test func graphBoundsAreInclusiveAndUnknownRowsDoNotBecomeZero() {
        let filter = GraphTableFilter(minimumFields: 4, maximumFields: 8, minimumRows: 0, maximumRows: 10)
        #expect(filter.matches(fields: 4, rows: 0, relations: 0))
        #expect(filter.matches(fields: 8, rows: 10, relations: 0))
        #expect(!filter.matches(fields: 3, rows: 0, relations: 0))
        #expect(!filter.matches(fields: 9, rows: 1, relations: 0))
        #expect(!filter.matches(fields: 5, rows: 11, relations: 0))
        #expect(!filter.matches(fields: 5, rows: nil, relations: 0))
        #expect(GraphTableFilter(minimumFields: 4).matches(fields: 5, rows: nil, relations: 0))
        #expect(!GraphTableFilter(minimumRows: 10, maximumRows: 2).isValid)
        #expect(!GraphTableFilter(minimumFields: -1).isValid)
        let relations = GraphTableFilter(minimumRelations: 1, maximumRelations: 3)
        #expect(relations.isActive)
        #expect(relations.matches(fields: 2, rows: nil, relations: 1))
        #expect(relations.matches(fields: 2, rows: nil, relations: 3))
        #expect(!relations.matches(fields: 2, rows: nil, relations: 0))
        #expect(!relations.matches(fields: 2, rows: nil, relations: 4))
        #expect(!GraphTableFilter(minimumRelations: -1).isValid)
        #expect(!GraphTableFilter(minimumRelations: 3, maximumRelations: 1).isValid)
    }

    @Test func relationFiltersCountConstraintsAcrossTheFullSchema() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in
            try db.execute(sql: """
                CREATE TABLE parent(a INTEGER, b INTEGER, PRIMARY KEY(a, b));
                CREATE TABLE child(id INTEGER PRIMARY KEY, first_a INTEGER, first_b INTEGER,
                    second_a INTEGER, second_b INTEGER, parent_child_id INTEGER REFERENCES child(id),
                    FOREIGN KEY(first_a, first_b) REFERENCES parent(a, b),
                    FOREIGN KEY(second_a, second_b) REFERENCES parent(a, b));
                CREATE TABLE leaf(id INTEGER PRIMARY KEY, child_id INTEGER REFERENCES child(id));
                CREATE TABLE isolated(id INTEGER PRIMARY KEY);
                INSERT INTO parent VALUES(1, 1), (2, 2);
                INSERT INTO child VALUES(1, 1, 1, 2, 2, NULL);
                INSERT INTO leaf VALUES(1, 1), (2, 1);
                """)
        }
        try database.close()
        let suite = "sgs-relations-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        #expect(session.presentedError == nil)
        // The two composite FKs count separately; their column pairs do not.
        // The child's self-reference counts once, plus one incoming leaf FK.
        #expect(session.graphRelationCounts["parent"] == 2)
        #expect(session.graphRelationCounts["child"] == 4)
        #expect(session.graphRelationCounts["leaf"] == 1)
        #expect(await session.applyGraphFilter(.init(minimumRelations: 0, maximumRelations: 0)))
        #expect(session.graphVisibleTableIDs == ["isolated"])
        #expect(session.graphRowCounts.isEmpty)
        #expect(await session.applyGraphFilter(.init(minimumRelations: 1, maximumRelations: 2)))
        #expect(session.graphVisibleTableIDs == ["parent", "leaf"])
        let combined = GraphTableFilter(minimumFields: 6, maximumFields: 6, minimumRows: 1, maximumRows: 1,
                                        minimumRelations: 4, maximumRelations: 4)
        #expect(await session.applyGraphFilter(combined))
        #expect(session.graphVisibleTableIDs == ["child"])
        #expect(session.graphRowCounts == ["child": 1])
        #expect(!(await session.applyGraphFilter(.init(minimumRelations: 5, maximumRelations: 4))))
        #expect(session.graphTableFilter == combined)
        #expect(await session.applyGraphFilter(.init(minimumRelations: 5)))
        #expect(session.graphVisibleTableIDs.isEmpty)
        session.clearGraphFilter()
        #expect(session.graphVisibleTableIDs.count == 4)
        await session.closeAndWait()
        #expect(session.graphRelationCounts.isEmpty)
    }

    @Test func publicPrefixIsOnlyHiddenInPostgresLabels() {
        let publicTable = TableSummary(name: "public.orders", objectType: .table, isEditable: false, columnCount: 2, schemaName: "public", objectName: "orders")
        let otherSchema = TableSummary(name: "archive.orders", objectType: .table, isEditable: false, columnCount: 2, schemaName: "archive", objectName: "orders")
        let sqlite = TableSummary(name: "public.orders", objectType: .table, isEditable: true, columnCount: 2)
        #expect(publicTable.displayName == "orders")
        #expect(publicTable.id == "public.orders")
        #expect(otherSchema.displayName == "archive.orders")
        #expect(sqlite.displayName == "public.orders")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"] != nil, "Requires a chosen PostgreSQL dump"))
    func everyDumpTableCanOpenRenderSortAndClose() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"]))
        let suite = "sgs-ux-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DatabaseService()
        let session = AppSession(databaseService: service, userDefaults: defaults)
        await session.openDocument(url: url)
        #expect(session.presentedError == nil)
        let names = session.tables.map(\.name)
        #expect(!names.isEmpty)
        let identityName = "public.field_research_public_query_identity"
        if names.contains(identityName) {
            let result = try await service.executeReadOnlyQuery(sql: """
                SELECT count(*) FROM pg_catalog.pg_constraint
                WHERE contype = 'f' AND (conrelid = 'public.field_research_public_query_identity'::regclass
                    OR confrelid = 'public.field_research_public_query_identity'::regclass)
                """)
            let expectedRelations = Int(try #require(result.rows.first?.values.first?.displayText))
            #expect(session.graphRelationCounts[identityName] == expectedRelations)
            #expect(await session.applyGraphFilter(.init(minimumRelations: expectedRelations, maximumRelations: expectedRelations)))
            #expect(session.graphVisibleTableIDs.contains(identityName))
            session.clearGraphFilter()
        }
        var emptyTables = 0
        var populatedTables = 0
        var cells = 0
        for name in names {
            let tab = try #require(session.openTable(named: name, autoLoad: false))
            tab.queryState.limit = 3
            await tab.reload()
            #expect(tab.inlineErrorMessage == nil, "\(name): \(tab.inlineErrorMessage ?? "")")
            if tab.chunk.rows.isEmpty { emptyTables += 1 } else { populatedTables += 1 }
            autoreleasepool {
                let coordinator = TableGridRepresentable.Coordinator(tab: tab, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, inspectRow: { _ in })
                let scroll = coordinator.makeScrollView()
                scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 340)
                coordinator.update(tab: tab, revision: tab.revision, columnDescription: { _ in nil }, requestColumnDrop: { _ in }, scrollView: scroll, inspectRow: { _ in })
                scroll.layoutSubtreeIfNeeded()
                #expect(scroll.contentView.clipsToBounds)
                guard let table = scroll.documentView as? NSTableView else { Issue.record("Missing native table"); return }
                #expect(table.headerView?.frame.height == 58)
                if let header = table.headerView {
                    #expect(!scroll.contentView.frame.intersects(header.convert(header.bounds, to: scroll)))
                }
                for column in table.tableColumns {
                    let copy = column.headerCell.copy() as! MetadataHeaderCell
                    #expect(copy.stringValue == column.title)
                    cells += 1
                }
                scroll.contentView.scroll(to: NSPoint(x: 150, y: 70))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(table.headerView?.frame.height == 58)
                if let header = table.headerView {
                    #expect(!scroll.contentView.frame.intersects(header.convert(header.bounds, to: scroll)))
                }
            }
            if let column = tab.descriptor.columns.first {
                tab.queryState.sort = SortState(columnName: column.name, direction: .descending)
                await tab.reload()
                #expect(tab.inlineErrorMessage == nil, "Sorting \(name): \(tab.inlineErrorMessage ?? "")")
            }
            session.closeTab(id: tab.id)
        }
        // Exercise fresh row counts, zero-row inclusion, intersecting field bounds,
        // no matches, and resetting without reloading the database.
        #expect(await session.applyGraphFilter(.init(minimumRows: 0, maximumRows: 0)))
        #expect(session.graphVisibleTableIDs.count == emptyTables)
        #expect(session.graphVisibleTableIDs.allSatisfy { session.graphRowCounts[$0] == 0 })
        let combined = GraphTableFilter(minimumFields: 10, maximumFields: 20, minimumRows: 1, maximumRows: 1_000)
        let expected = Set(session.tables.filter {
            (10...20).contains($0.columnCount) && (1...1_000).contains(session.graphRowCounts[$0.id] ?? -1)
        }.map(\.id))
        #expect(await session.applyGraphFilter(combined))
        #expect(session.graphVisibleTableIDs == expected)
        #expect(!(await session.applyGraphFilter(.init(minimumRows: 10, maximumRows: 2))))
        #expect(session.graphTableFilter == combined)
        #expect(await session.applyGraphFilter(.init(minimumFields: 100_000)))
        #expect(session.graphVisibleTableIDs.isEmpty)
        session.clearGraphFilter()
        #expect(session.graphVisibleTableIDs.count == names.count)
        print("Dump UI matrix: \(names.count) tables/views opened and sorted; \(populatedTables) populated, \(emptyTables) empty; \(cells) header cells copied; graph range filters verified")
        await service.close()
    }
}
