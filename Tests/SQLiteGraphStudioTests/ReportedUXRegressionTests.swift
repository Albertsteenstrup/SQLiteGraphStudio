import AppKit
import Foundation
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
        #expect(filter.matches(fields: 4, rows: 0))
        #expect(filter.matches(fields: 8, rows: 10))
        #expect(!filter.matches(fields: 3, rows: 0))
        #expect(!filter.matches(fields: 9, rows: 1))
        #expect(!filter.matches(fields: 5, rows: 11))
        #expect(!filter.matches(fields: 5, rows: nil))
        #expect(GraphTableFilter(minimumFields: 4).matches(fields: 5, rows: nil))
        #expect(!GraphTableFilter(minimumRows: 10, maximumRows: 2).isValid)
        #expect(!GraphTableFilter(minimumFields: -1).isValid)
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
