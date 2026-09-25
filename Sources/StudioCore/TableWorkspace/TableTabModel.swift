import Foundation
import Observation

@MainActor
@Observable
public final class TableTabModel: Identifiable {
    public let id = UUID()
    public let descriptor: EditableTableDescriptor
    public private(set) var chunk: TableChunk
    public var queryState: TableQueryState
    public var isLoading = false
    public var inlineErrorMessage: String?
    public var busyError: SQLiteUserError?
    public private(set) var revision = 0
    public private(set) var viewportRequestID = 0
    public private(set) var viewportRow = 0

    private let databaseService: DatabaseService
    private var latestRequestID = 0
    private var pendingRetryChange: CellEditChange?
    private var pendingOffset: Int?
    private var cursors: [Int: TablePageCursor] = [:]
    private var loadedQuery: TableQueryState?

    public init(
        descriptor: EditableTableDescriptor,
        databaseService: DatabaseService,
        state: TableQueryState = TableQueryState()
    ) {
        self.descriptor = descriptor
        self.databaseService = databaseService
        self.queryState = state
        self.chunk = .empty(limit: state.limit)
    }

    public var title: String {
        descriptor.displayName
    }

    public var rowCountLabel: String {
        chunk.countState.label
    }

    public var isEditable: Bool {
        descriptor.isEditable
    }

    public func filterValue(for columnName: String) -> String {
        queryState.columnFilters.first(where: { $0.columnName == columnName })?.value ?? ""
    }

    public var hasColumnFilters: Bool {
        !queryState.sanitizedFilters.isEmpty
    }

    public func applySort(_ sort: SortState?) {
        queryState.sort = sort
        queryState.offset = 0
        Task { await reload() }
    }

    public func row(at absoluteRow: Int) -> TableRow? {
        guard chunk.contains(absoluteRow: absoluteRow) else { return nil }
        return chunk.rows[absoluteRow - chunk.offset]
    }

    public func displayedValue(row: Int, column: Int) -> String {
        guard let tableRow = self.row(at: row), tableRow.values.indices.contains(column) else { return "…" }
        if tableRow.omittedColumnIndices.contains(column) { return "Large value — inspect in slices" }
        return tableRow.values[column].displayText
    }

    public func isValueOmitted(row: Int, column: Int) -> Bool {
        self.row(at: row)?.omittedColumnIndices.contains(column) ?? false
    }

    public func canReadOmittedCell(row absoluteRow: Int, columnName: String) -> Bool {
        guard let tableRow = row(at: absoluteRow),
              let columnIndex = descriptor.columns.firstIndex(where: { $0.name == columnName }),
              tableRow.omittedColumnIndices.contains(columnIndex),
              let loadedQuery else { return false }
        return loadedQuery.searchText == queryState.searchText
            && loadedQuery.sanitizedFilters == queryState.sanitizedFilters
            && loadedQuery.sort == queryState.sort
            && loadedQuery.offset == queryState.offset
            && loadedQuery.after == queryState.after
    }

    /// Reads a small database-side slice for a cell omitted from the table grid.
    /// The absolute row index keeps this correct after cursor-based page navigation;
    /// the bounded projection ensures the full cell never enters the app process.
    /// Its loaded primary key or rowid is checked in the same query to reject an
    /// external insert or delete that shifted this offset after the grid loaded.
    public func readOmittedCell(row absoluteRow: Int, columnName: String, offset: Int = 0,
                                length: Int = 4_096) async throws -> BoundedCellRead? {
        guard canReadOmittedCell(row: absoluteRow, columnName: columnName) else {
            guard let tableRow = row(at: absoluteRow),
                  let columnIndex = descriptor.columns.firstIndex(where: { $0.name == columnName }),
                  tableRow.omittedColumnIndices.contains(columnIndex) else {
                throw DatabaseUserError(kind: .invalidInput, message: "Only large values omitted from the grid can be inspected in slices.")
            }
            throw DatabaseUserError(kind: .invalidInput, message: "The table query is changing. Wait for the rows to finish loading, then inspect the cell again.")
        }
        guard let loadedQuery else {
            throw DatabaseUserError(kind: .invalidInput, message: "The table query is changing. Wait for the rows to finish loading, then inspect the cell again.")
        }
        guard let expectedRowIdentity = row(at: absoluteRow)?.identity else {
            throw DatabaseUserError(kind: .invalidInput, message: "The selected cell is no longer available.")
        }

        var boundedQuery = loadedQuery
        boundedQuery.offset = absoluteRow
        boundedQuery.after = nil
        boundedQuery.requestExactCount = false
        boundedQuery.cachedExactCount = nil
        return try await databaseService.readBoundedCell(
            query: boundedQuery,
            descriptor: descriptor,
            columnName: columnName,
            offset: offset,
            length: length,
            expectedRowIdentity: expectedRowIdentity
        )
    }

    /// Runs a multi-slice cell action against one database snapshot, using the
    /// exact query and row identity that produced the currently visible grid row.
    public func withOmittedCellReadSnapshot<T: Sendable>(
        row absoluteRow: Int,
        columnName: String,
        operation: @escaping @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> T
    ) async throws -> T {
        guard canReadOmittedCell(row: absoluteRow, columnName: columnName) else {
            guard let tableRow = row(at: absoluteRow),
                  let columnIndex = descriptor.columns.firstIndex(where: { $0.name == columnName }),
                  tableRow.omittedColumnIndices.contains(columnIndex) else {
                throw DatabaseUserError(kind: .invalidInput, message: "Only large values omitted from the grid can be inspected in slices.")
            }
            throw DatabaseUserError(kind: .invalidInput, message: "The table query is changing. Wait for the rows to finish loading, then inspect the cell again.")
        }
        guard let loadedQuery else {
            throw DatabaseUserError(kind: .invalidInput, message: "The table query is changing. Wait for the rows to finish loading, then inspect the cell again.")
        }
        guard let expectedRowIdentity = row(at: absoluteRow)?.identity else {
            throw DatabaseUserError(kind: .invalidInput, message: "The selected row is no longer available.")
        }

        var boundedQuery = loadedQuery
        boundedQuery.offset = absoluteRow
        boundedQuery.after = nil
        boundedQuery.requestExactCount = false
        boundedQuery.cachedExactCount = nil
        return try await databaseService.withBoundedCellReadSnapshot(
            query: boundedQuery,
            descriptor: descriptor,
            columnName: columnName,
            expectedRowIdentity: expectedRowIdentity,
            operation: operation
        )
    }

    public func canEditCell(row: Int, column: Int) -> Bool {
        guard isEditable,
              descriptor.columns.indices.contains(column),
              descriptor.columns[column].isEditable,
              let tableRow = self.row(at: row) else { return false }
        return !tableRow.omittedColumnIndices.contains(column)
    }

    public func reload(centeringRow targetRow: Int? = nil, moveViewport: Bool = false) async {
        let nextOffset = targetRow.map { $0 >= chunk.rowRange.upperBound ? chunk.rowRange.upperBound : max(0, $0 - queryState.limit / 2) } ?? queryState.offset
        if let previous = loadedQuery, previous.searchText != queryState.searchText || previous.sanitizedFilters != queryState.sanitizedFilters || previous.sort != queryState.sort {
            cursors = [:]
            queryState.after = nil
            queryState.cachedExactCount = nil
        }
        if nextOffset == chunk.rowRange.upperBound, nextOffset > 0, !descriptor.paginationKeyColumns.isEmpty, let last = chunk.rows.last {
            var values = Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), last.values))
            if case .rowID(let id) = last.identity { values["_rowid_"] = .integer(id) }
            // A cursor is valid only for the predicates/order that produced it.
            if loadedQuery?.searchText == queryState.searchText && loadedQuery?.sanitizedFilters == queryState.sanitizedFilters && loadedQuery?.sort == queryState.sort {
                cursors[nextOffset] = .init(values: values)
            }
        }
        queryState.after = cursors[nextOffset]
        queryState.offset = nextOffset
        pendingOffset = nextOffset
        latestRequestID += 1
        let requestID = latestRequestID
        defer {
            if requestID == latestRequestID { isLoading = false }
        }

        isLoading = true
        inlineErrorMessage = nil

        let requestedQuery = queryState
        var fetchQuery = requestedQuery
        fetchQuery.omitOversizedCells = true
        do {
            let result = try await databaseService.fetchChunk(query: fetchQuery, descriptor: descriptor)
            guard !Task.isCancelled, requestID == latestRequestID else { return }
            chunk = result
            loadedQuery = requestedQuery
            if queryState == requestedQuery, case .exact(let count) = result.countState { queryState.cachedExactCount = count }
            if moveViewport { viewportRow = result.offset; viewportRequestID &+= 1 }
            pendingOffset = nil
            revision &+= 1
        } catch {
            guard !Task.isCancelled, requestID == latestRequestID else { return }
            let userError = SQLiteUserError.from(error)
            inlineErrorMessage = userError.message
            revision &+= 1
        }

    }

    public func ensureVisible(row: Int) {
        guard row >= 0 else { return }
        guard chunk.totalRowCount > 0 else { return }
        guard row < chunk.totalRowCount else { return }
        if chunk.contains(absoluteRow: row) { return }
        if let pendingOffset {
            let pendingRange = pendingOffset..<(pendingOffset + queryState.limit)
            if pendingRange.contains(row) {
                return
            }
        }
        Task { await reload(centeringRow: row, moveViewport: row >= chunk.rowRange.upperBound) }
    }

    public func nextPage() { guard chunk.hasMore, !isLoading else { return }; queryState.offset = chunk.rowRange.upperBound; Task { await reload(moveViewport: true) } }
    public func previousPage() { guard !isLoading else { return }; queryState.offset = max(0, chunk.offset - queryState.limit); Task { await reload(moveViewport: true) } }
    private func invalidatePagination() {
        queryState.cachedExactCount = nil
        queryState.after = nil
        cursors = [:]
        loadedQuery = nil
    }
    public func refresh() {
        invalidatePagination()
        queryState.offset = 0
        Task { await reload() }
    }
    public func countExactly() {
        let filters = queryState
        Task {
            do {
                let count = try await databaseService.countRows(query: filters, descriptor: descriptor)
                guard queryState.searchText == filters.searchText, queryState.sanitizedFilters == filters.sanitizedFilters else { return }
                queryState.cachedExactCount = count
                await reload()
            } catch { inlineErrorMessage = SQLiteUserError.from(error).message }
        }
    }

    public func updateSearch(_ value: String) {
        queryState.searchText = value
        queryState.offset = 0
        Task { await reload() }
    }

    public func updateColumnFilters(_ filters: [ColumnFilter]) {
        queryState.columnFilters = filters
        queryState.offset = 0
        Task { await reload() }
    }

    public func updateFilterValue(_ value: String, for columnName: String) {
        var filters = queryState.columnFilters
        filters.removeAll { $0.columnName == columnName }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            filters.append(ColumnFilter(columnName: columnName, value: trimmed))
        }
        updateColumnFilters(filters)
    }

    public func toggleSort(for columnName: String) {
        if let existingSort = queryState.sort, existingSort.columnName == columnName {
            queryState.sort = SortState(columnName: columnName, direction: existingSort.direction.toggled)
        } else {
            queryState.sort = SortState(columnName: columnName, direction: .ascending)
        }
        queryState.offset = 0
        Task { await reload() }
    }

    /// Returns the task that saves the edit and reloads the grid, or nil when
    /// the edit is rejected before any database work starts.
    @discardableResult
    public func commitEdit(row absoluteRow: Int, columnName: String, rawValue: String) -> Task<Void, Never>? {
        guard let row = row(at: absoluteRow) else { return nil }
        guard let columnIndex = descriptor.columns.firstIndex(where: { $0.name == columnName }) else {
            inlineErrorMessage = "This table is read-only."
            return nil
        }
        guard !row.omittedColumnIndices.contains(columnIndex) else {
            inlineErrorMessage = "Large values are read-only in the grid. Inspect them in slices."
            return nil
        }
        guard canEditCell(row: absoluteRow, column: columnIndex) else {
            inlineErrorMessage = "This table is read-only."
            return nil
        }
        let change = CellEditChange(
            descriptor: descriptor,
            rowIdentity: row.identity,
            columnName: columnName,
            rawValue: rawValue
        )

        return Task {
            do {
                try await databaseService.commitEdit(change)
                inlineErrorMessage = nil
                invalidatePagination()
                await reload(centeringRow: absoluteRow)
            } catch {
                let mapped = SQLiteUserError.from(error)
                if mapped.kind == .busy {
                    busyError = mapped
                    pendingRetryChange = change
                } else {
                    inlineErrorMessage = mapped.message
                }
            }
        }
    }

    public func retryPendingEdit() {
        guard isEditable, let pendingRetryChange else { return }
        busyError = nil
        self.pendingRetryChange = nil
        Task {
            do {
                try await databaseService.commitEdit(pendingRetryChange)
                invalidatePagination()
                await reload()
            } catch {
                let mapped = SQLiteUserError.from(error)
                if mapped.kind == .busy {
                    busyError = mapped
                    self.pendingRetryChange = pendingRetryChange
                } else {
                    inlineErrorMessage = mapped.message
                }
            }
        }
    }

    public func clearBusyError() {
        busyError = nil
        pendingRetryChange = nil
    }

    public func dropColumn(_ columnName: String) async throws {
        guard isEditable, descriptor.columns.contains(where: { $0.name == columnName && $0.canDropInSQLite }) else {
            throw DatabaseUserError(kind: .readOnly, message: "Columns cannot be changed on a read-only table.")
        }
        try await databaseService.dropColumn(columnName: columnName, from: descriptor)
    }

    public func insertEmptyRow() {
        guard isEditable else {
            inlineErrorMessage = "This table is read-only."
            return
        }
        Task {
            do {
                try await databaseService.insertDefaultRow(into: descriptor)
                inlineErrorMessage = nil
                invalidatePagination()
                await reload(centeringRow: 0)
            } catch {
                inlineErrorMessage = SQLiteUserError.from(error).message
            }
        }
    }

    public func cloneRow(at absoluteRow: Int) {
        guard isEditable else {
            inlineErrorMessage = "This table is read-only."
            return
        }
        guard let row = row(at: absoluteRow) else { return }
        guard row.omittedColumnIndices.isEmpty else {
            inlineErrorMessage = "This row contains large values omitted from the grid and cannot be cloned from this page."
            return
        }
        Task {
            do {
                try await databaseService.insertClonedRow(from: row, into: descriptor)
                inlineErrorMessage = nil
                invalidatePagination()
                await reload(centeringRow: 0)
            } catch {
                inlineErrorMessage = SQLiteUserError.from(error).message
            }
        }
    }

    public func deleteRow(at absoluteRow: Int) {
        guard isEditable else {
            inlineErrorMessage = "This table is read-only."
            return
        }
        guard let row = row(at: absoluteRow) else { return }
        Task {
            do {
                try await databaseService.deleteRow(row.identity, from: descriptor)
                inlineErrorMessage = nil
                invalidatePagination()
                await reload(centeringRow: max(0, absoluteRow - 1))
            } catch {
                inlineErrorMessage = SQLiteUserError.from(error).message
            }
        }
    }
}
