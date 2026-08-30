import Foundation

/// The operations shared by every database target. The facade owns target
/// selection; each backend owns the wire/storage-specific implementation.
public protocol DatabaseBackend: AnyObject, Sendable {
    var capabilities: DatabaseCapabilities { get }

    func close() async
    func listTables() async throws -> [TableSummary]
    func loadSchemaGraph() async throws -> SchemaGraph
    func loadCatalogSnapshot() async throws -> CatalogSnapshot
    func fetchDescriptor(named tableName: String) async throws -> EditableTableDescriptor
    func fetchChunk(query: TableQueryState, descriptor: EditableTableDescriptor) async throws -> TableChunk
    func commitEdit(_ change: CellEditChange) async throws
    func insertDefaultRow(into descriptor: EditableTableDescriptor) async throws
    func insertClonedRow(from sourceRow: TableRow, into descriptor: EditableTableDescriptor) async throws
    func deleteRow(_ identity: TableRowIdentity, from descriptor: EditableTableDescriptor) async throws
    func dropColumn(columnName: String, from descriptor: EditableTableDescriptor) async throws
    func createTable(_ draft: TableCreateDraft) async throws
    func renameTable(from currentName: String, to newName: String) async throws
    func addColumn(_ draft: TableColumnDraft, to descriptor: EditableTableDescriptor) async throws
    func renameColumn(from currentName: String, to newName: String, in descriptor: EditableTableDescriptor) async throws
    func executeReadOnlyQuery(sql: String, rowLimit: Int) async throws -> QueryResult
    func explainQueryPlan(sql: String) async throws -> [ExplainPlanRow]
    func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) async throws -> String
    func serializeTableRows(descriptor: EditableTableDescriptor, rows: [TableRow], format: DataTransferFormat) async throws -> String
    func importRows(into descriptor: EditableTableDescriptor, text: String, format: DataTransferFormat) async throws -> ImportRowsResult
}

public actor DatabaseService {
    private enum Backend: Sendable {
        case sqlite(SQLiteDatabaseBackend)
        case postgres(PostgresDatabaseBackend)

        var value: any DatabaseBackend {
            switch self {
            case .sqlite(let backend):
                return backend
            case .postgres(let backend):
                return backend
            }
        }
    }

    private var backend: Backend?
    public private(set) var currentTarget: DatabaseTarget?

    public init() {}

    public var capabilities: DatabaseCapabilities {
        backend?.value.capabilities ?? .none
    }

    public var isPostgreSQL: Bool {
        if case .postgres = backend { return true }
        return false
    }

    public func open(url: URL) async throws {
        await close()
        let normalizedURL = url.standardizedFileURL
        let sqlite = SQLiteDatabaseBackend()
        try await sqlite.open(url: normalizedURL)
        backend = .sqlite(sqlite)
        currentTarget = .sqlite(normalizedURL)
    }

    public func open(postgres configuration: PostgresConnectionConfiguration) async throws {
        await close()
        let postgres = PostgresDatabaseBackend(configuration: configuration)
        try await postgres.open()
        backend = .postgres(postgres)
        currentTarget = .postgres(configuration)
    }

    public func open(target: DatabaseTarget) async throws {
        switch target {
        case .sqlite(let url):
            try await open(url: url)
        case .postgres(let configuration):
            try await open(postgres: configuration)
        }
    }

    public func close() async {
        if let backend {
            await backend.value.close()
        }
        backend = nil
        currentTarget = nil
    }

    public func listTables() async throws -> [TableSummary] {
        try await requireBackend().listTables()
    }

    public func loadSchemaGraph() async throws -> SchemaGraph {
        try await requireBackend().loadSchemaGraph()
    }

    public func loadCatalogSnapshot() async throws -> CatalogSnapshot {
        try await requireBackend().loadCatalogSnapshot()
    }

    public func fetchDescriptor(named tableName: String) async throws -> EditableTableDescriptor {
        try await requireBackend().fetchDescriptor(named: tableName)
    }

    public func fetchChunk(query: TableQueryState, descriptor: EditableTableDescriptor) async throws -> TableChunk {
        try await requireBackend().fetchChunk(query: query, descriptor: descriptor)
    }

    public func commitEdit(_ change: CellEditChange) async throws {
        try await requireBackend().commitEdit(change)
    }

    public func insertDefaultRow(into descriptor: EditableTableDescriptor) async throws {
        try await requireBackend().insertDefaultRow(into: descriptor)
    }

    public func insertClonedRow(from sourceRow: TableRow, into descriptor: EditableTableDescriptor) async throws {
        try await requireBackend().insertClonedRow(from: sourceRow, into: descriptor)
    }

    public func deleteRow(_ identity: TableRowIdentity, from descriptor: EditableTableDescriptor) async throws {
        try await requireBackend().deleteRow(identity, from: descriptor)
    }

    public func dropColumn(columnName: String, from descriptor: EditableTableDescriptor) async throws {
        try await requireBackend().dropColumn(columnName: columnName, from: descriptor)
    }

    public func createTable(_ draft: TableCreateDraft) async throws {
        try await requireBackend().createTable(draft)
    }

    public func renameTable(from currentName: String, to newName: String) async throws {
        try await requireBackend().renameTable(from: currentName, to: newName)
    }

    public func addColumn(_ draft: TableColumnDraft, to descriptor: EditableTableDescriptor) async throws {
        try await requireBackend().addColumn(draft, to: descriptor)
    }

    public func renameColumn(from currentName: String, to newName: String, in descriptor: EditableTableDescriptor) async throws {
        try await requireBackend().renameColumn(from: currentName, to: newName, in: descriptor)
    }

    public func executeReadOnlyQuery(sql: String, rowLimit: Int = 500) async throws -> QueryResult {
        try await requireBackend().executeReadOnlyQuery(sql: sql, rowLimit: rowLimit)
    }

    public func explainQueryPlan(sql: String) async throws -> [ExplainPlanRow] {
        try await requireBackend().explainQueryPlan(sql: sql)
    }

    public func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) async throws -> String {
        try await requireBackend().serializeQueryResult(result, format: format)
    }

    public func serializeTableRows(descriptor: EditableTableDescriptor, rows: [TableRow], format: DataTransferFormat) async throws -> String {
        try await requireBackend().serializeTableRows(descriptor: descriptor, rows: rows, format: format)
    }

    public func importRows(into descriptor: EditableTableDescriptor, text: String, format: DataTransferFormat) async throws -> ImportRowsResult {
        try await requireBackend().importRows(into: descriptor, text: text, format: format)
    }

    public nonisolated func makeCreateTableSQL(_ draft: TableCreateDraft) throws -> String {
        try SQLiteDatabaseBackend().makeCreateTableSQL(draft)
    }

    private func requireBackend() throws -> any DatabaseBackend {
        guard let backend else {
            throw DatabaseUserError(kind: .generic, message: "No database is open.")
        }
        return backend.value
    }
}

extension SQLiteDatabaseBackend: DatabaseBackend {}
