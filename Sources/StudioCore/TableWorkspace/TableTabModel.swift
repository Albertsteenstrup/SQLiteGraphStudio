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

    private let databaseService: DatabaseService
    private var latestRequestID = 0
    private var pendingRetryChange: CellEditChange?
    private var pendingOffset: Int?

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
        descriptor.name
    }

    public var rowCountLabel: String {
        "\(chunk.totalRowCount.formatted()) rows"
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
        return tableRow.values[column].displayText
    }

    public func reload(centeringRow targetRow: Int? = nil) async {
        let nextOffset = targetRow.map { max(0, $0 - queryState.limit / 2) } ?? queryState.offset
        queryState.offset = nextOffset
        pendingOffset = nextOffset
        latestRequestID += 1
        let requestID = latestRequestID

        isLoading = true
        inlineErrorMessage = nil

        do {
            let result = try await databaseService.fetchChunk(query: queryState, descriptor: descriptor)
            guard requestID == latestRequestID else { return }
            chunk = result
            pendingOffset = nil
            revision &+= 1
        } catch {
            guard requestID == latestRequestID else { return }
            let userError = SQLiteUserError.from(error)
            inlineErrorMessage = userError.message
            revision &+= 1
        }

        if requestID == latestRequestID {
            isLoading = false
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
        Task { await reload(centeringRow: row) }
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

    public func commitEdit(row absoluteRow: Int, columnName: String, rawValue: String) {
        guard let row = row(at: absoluteRow) else { return }
        let change = CellEditChange(
            descriptor: descriptor,
            rowIdentity: row.identity,
            columnName: columnName,
            rawValue: rawValue
        )

        Task {
            do {
                try await databaseService.commitEdit(change)
                inlineErrorMessage = nil
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
        guard let pendingRetryChange else { return }
        busyError = nil
        self.pendingRetryChange = nil
        Task {
            do {
                try await databaseService.commitEdit(pendingRetryChange)
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
        try await databaseService.dropColumn(columnName: columnName, from: descriptor)
    }
}
