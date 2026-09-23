import Foundation

/// Reads successive, bounded slices from one database snapshot. The reader is
/// valid only while its enclosing snapshot operation is running.
public struct BoundedCellSnapshotReader: Sendable {
    private let readSlice: @MainActor @Sendable (Int, Int) async throws -> BoundedCellRead?

    init(readSlice: @escaping @MainActor @Sendable (Int, Int) async throws -> BoundedCellRead?) {
        self.readSlice = readSlice
    }

    public func read(offset: Int, length: Int = 4_096) async throws -> BoundedCellRead? {
        try Task.checkCancellation()
        guard offset >= 0, offset < Int.max, (1...4_096).contains(length) else {
            throw DatabaseUserError(kind: .invalidInput, message: "Snapshot cell slices require a nonnegative offset and a length from 1 to 4096.")
        }
        return try await readSlice(offset, length)
    }
}

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
    func readBoundedCell(query: TableQueryState, descriptor: EditableTableDescriptor, columnName: String, offset: Int, length: Int, expectedRowIdentity: TableRowIdentity?) async throws -> BoundedCellRead?
    func withBoundedCellReadSnapshot<T: Sendable>(
        query: TableQueryState,
        descriptor: EditableTableDescriptor,
        columnName: String,
        expectedRowIdentity: TableRowIdentity?,
        operation: @escaping @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> T
    ) async throws -> T
    func fetchRecords(descriptor: TableDescriptor, predicates: [IdentityComponent], offset: Int, limit: Int) async throws -> RecordPage
    func fetchRelated(record: RecordSnapshot, relationship: RecordRelationship, direction: RecordDirection, offset: Int, limit: Int) async throws -> RecordPage
    func commitEdit(_ change: CellEditChange) async throws
    func insertDefaultRow(into descriptor: EditableTableDescriptor) async throws
    func insertClonedRow(from sourceRow: TableRow, into descriptor: EditableTableDescriptor) async throws
    func deleteRow(_ identity: TableRowIdentity, from descriptor: EditableTableDescriptor) async throws
    func dropColumn(columnName: String, from descriptor: EditableTableDescriptor) async throws
    func createTable(_ draft: TableCreateDraft) async throws
    func renameTable(from currentName: String, to newName: String) async throws
    func addColumn(_ draft: TableColumnDraft, to descriptor: EditableTableDescriptor) async throws
    func renameColumn(from currentName: String, to newName: String, in descriptor: EditableTableDescriptor) async throws
    func executeReadOnlyQuery(sql: String, rowLimit: Int, timeoutSeconds: TimeInterval) async throws -> QueryResult
    func explainQueryPlan(sql: String, timeoutSeconds: TimeInterval) async throws -> [ExplainPlanRow]
    func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) async throws -> String
    func serializeTableRows(descriptor: EditableTableDescriptor, rows: [TableRow], format: DataTransferFormat) async throws -> String
    func exportTableRows(query: TableQueryState, descriptor: TableDescriptor, to destination: URL, format: DataTransferFormat,
                         timeoutSeconds: TimeInterval, cancellation: ExportCancellation, failIfExists: Bool,
                         progress: @escaping @Sendable (Int) -> Void) async throws -> Int
    func importRows(into descriptor: EditableTableDescriptor, text: String, format: DataTransferFormat) async throws -> ImportRowsResult
}

public extension DatabaseBackend {
    /// Compatibility entry point for callers that address a cell by its current
    /// query offset without carrying a previously loaded row identity.
    func readBoundedCell(query: TableQueryState, descriptor: EditableTableDescriptor, columnName: String,
                         offset: Int = 0, length: Int = 4_096) async throws -> BoundedCellRead? {
        try await readBoundedCell(query: query, descriptor: descriptor, columnName: columnName,
                                  offset: offset, length: length, expectedRowIdentity: nil)
    }

    /// Backends must explicitly provide a stable snapshot before they can
    /// support actions that span multiple cell slices.
    func withBoundedCellReadSnapshot<T: Sendable>(
        query: TableQueryState,
        descriptor: EditableTableDescriptor,
        columnName: String,
        expectedRowIdentity: TableRowIdentity?,
        operation: @escaping @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> T
    ) async throws -> T {
        throw DatabaseUserError(kind: .invalidInput,
                                message: "Full-value actions are unavailable because this database source cannot provide a consistent read snapshot.")
    }
}

public actor DatabaseService {
    private enum Backend: Sendable {
        case sqlite(SQLiteDatabaseBackend)
        case postgres(PostgresDatabaseBackend)
        case migrations(MigrationSchemaBackend)

        var value: any DatabaseBackend {
            switch self {
            case .sqlite(let backend):
                return backend
            case .postgres(let backend):
                return backend
            case .migrations(let backend):
                return backend
            }
        }
    }

    private var backend: Backend?
    private var dumpLease: PostgresDumpLease?
    var dumpSession: PostgresDumpSession? { dumpLease?.session }
    private var pendingCleanup: Task<Void, Never>?
    private var openGeneration = UUID()
    public private(set) var currentTarget: DatabaseTarget?

    public init() {}

    public var capabilities: DatabaseCapabilities {
        backend?.value.capabilities ?? .none
    }

    public var isPostgreSQL: Bool {
        if case .postgres = backend { return true }
        return false
    }

    public var isMigrationModel: Bool {
        if case .migrations = backend { return true }
        return false
    }

    /// Replay statistics and unparsed-statement diagnostics for an open migration model.
    public var migrationModel: MigrationSchemaModel? {
        get async {
            guard case .migrations(let backend) = backend else { return nil }
            return await backend.schemaModel
        }
    }

    public func open(url: URL, readOnly: Bool = false, includeRowCounts: Bool = true) async throws {
        let generation = try await beginOpen()
        let normalizedURL = url.standardizedFileURL
        let sqlite = SQLiteDatabaseBackend()
        try await sqlite.open(url: normalizedURL, readOnly: readOnly, includeRowCounts: includeRowCounts)
        guard openGeneration == generation, !Task.isCancelled else { await sqlite.close(); throw CancellationError() }
        backend = .sqlite(sqlite)
        currentTarget = .sqlite(normalizedURL)
    }

    public func open(postgres configuration: PostgresConnectionConfiguration, unixSocketPath: String? = nil) async throws {
        let generation = try await beginOpen()
        let postgres = PostgresDatabaseBackend(configuration: configuration, unixSocketPath: unixSocketPath)
        try await postgres.open()
        guard openGeneration == generation, !Task.isCancelled else { await postgres.close(); throw CancellationError() }
        backend = .postgres(postgres)
        currentTarget = .postgres(configuration)
    }

    public func open(target: DatabaseTarget) async throws {
        switch target {
        case .sqlite(let url):
            try await open(url: url)
        case .postgres(let configuration):
            try await open(postgres: configuration)
        case .postgresDump(let url):
            try await open(dump: url)
        case .migrations(let url):
            try await open(migrations: ProjectScanner.migrationSet(at: url), through: nil, sourceURL: url)
        }
    }

    /// Replays `set` up to and including `version` (its latest when nil). The
    /// target keeps the chosen `sourceURL` so layout, saved queries and notes
    /// stay with the migration set rather than with one revision of it.
    public func open(
        migrations set: MigrationSet,
        through version: String?,
        sourceURL: URL,
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws {
        let generation = try await beginOpen()
        let migrations = MigrationSchemaBackend()
        do {
            try await migrations.open(set: set, through: version, progress: progress)
            guard openGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            backend = .migrations(migrations)
            currentTarget = .migrations(sourceURL.standardizedFileURL)
        } catch {
            await migrations.close()
            throw error
        }
    }

    public func open(dump url: URL, progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        let generation = try await beginOpen()
        let lease = try await PostgresDumpRegistry.shared.acquire(url: url, progress: progress)
        let dump = lease.session
        let postgres = PostgresDatabaseBackend(configuration: dump.configuration, unixSocketPath: dump.socketPath)
        do {
            guard openGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            try await postgres.open()
            guard openGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            dumpLease = lease
            backend = .postgres(postgres)
            currentTarget = .postgresDump(url.standardizedFileURL)
        } catch {
            await postgres.close()
            await lease.release()
            throw error
        }
    }

    private func beginOpen() async throws -> UUID {
        let generation = UUID()
        openGeneration = generation
        await retireCurrentBackend().value
        guard openGeneration == generation, !Task.isCancelled else { throw CancellationError() }
        return generation
    }

    private func retireCurrentBackend() -> Task<Void, Never> {
        let previousCleanup = pendingCleanup
        let previous = backend
        let previousDumpLease = dumpLease
        backend = nil
        dumpLease = nil
        currentTarget = nil
        // Keep teardown owned while actor reentrancy allows another open or
        // Quit to enter. Every later transition joins the same cleanup chain.
        let cleanup = Task {
            await previousCleanup?.value
            await previous?.value.close()
            await previousDumpLease?.release()
        }
        pendingCleanup = cleanup
        return cleanup
    }

    public func close() async {
        openGeneration = UUID()
        await retireCurrentBackend().value
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

    public func readBoundedCell(query: TableQueryState, descriptor: EditableTableDescriptor, columnName: String,
                                offset: Int = 0, length: Int = 4_096,
                                expectedRowIdentity: TableRowIdentity? = nil) async throws -> BoundedCellRead? {
        try await requireBackend().readBoundedCell(query: query, descriptor: descriptor, columnName: columnName,
                                                   offset: offset, length: length, expectedRowIdentity: expectedRowIdentity)
    }

    /// Keeps a read-only database snapshot open for the complete callback so
    /// every bounded slice comes from one stable version of the selected row.
    public func withBoundedCellReadSnapshot<T: Sendable>(
        query: TableQueryState,
        descriptor: EditableTableDescriptor,
        columnName: String,
        expectedRowIdentity: TableRowIdentity?,
        operation: @escaping @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> T
    ) async throws -> T {
        try await requireBackend().withBoundedCellReadSnapshot(
            query: query,
            descriptor: descriptor,
            columnName: columnName,
            expectedRowIdentity: expectedRowIdentity,
            operation: operation
        )
    }

    public nonisolated func recordRelationships(catalog: CatalogSnapshot) -> [RecordRelationship] {
        RecordAccess.relationships(catalog: catalog)
    }

    public func fetchRecords(descriptor: TableDescriptor, predicates: [IdentityComponent], offset: Int = 0, limit: Int = 50) async throws -> RecordPage {
        try await requireBackend().fetchRecords(descriptor: descriptor, predicates: predicates, offset: offset, limit: limit)
    }

    public func fetchRelated(record: RecordSnapshot, relationship: RecordRelationship, direction: RecordDirection, offset: Int = 0, limit: Int = 50) async throws -> RecordPage {
        try await requireBackend().fetchRelated(record: record, relationship: relationship, direction: direction, offset: offset, limit: limit)
    }

    public func countRows(query: TableQueryState, descriptor: TableDescriptor) async throws -> Int {
        var countQuery = query
        countQuery.offset = 0
        countQuery.limit = 0
        countQuery.after = nil
        countQuery.cachedExactCount = nil
        countQuery.requestExactCount = true
        return try await requireBackend().fetchChunk(query: countQuery, descriptor: descriptor).totalRowCount
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

    public func executeReadOnlyQuery(sql: String, rowLimit: Int = 500, timeoutSeconds: TimeInterval = 30) async throws -> QueryResult {
        try await requireBackend().executeReadOnlyQuery(sql: sql, rowLimit: rowLimit, timeoutSeconds: timeoutSeconds)
    }

    public func explainQueryPlan(sql: String, timeoutSeconds: TimeInterval = 30) async throws -> [ExplainPlanRow] {
        try await requireBackend().explainQueryPlan(sql: sql, timeoutSeconds: timeoutSeconds)
    }

    public func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) async throws -> String {
        try await requireBackend().serializeQueryResult(result, format: format)
    }

    public func serializeTableRows(descriptor: EditableTableDescriptor, rows: [TableRow], format: DataTransferFormat) async throws -> String {
        try await requireBackend().serializeTableRows(descriptor: descriptor, rows: rows, format: format)
    }

    public func exportTableRows(query: TableQueryState, descriptor: TableDescriptor, to destination: URL, format: DataTransferFormat,
                                timeoutSeconds: TimeInterval = 300, expectedTarget: DatabaseTarget? = nil, cancellation: ExportCancellation = ExportCancellation(),
                                failIfExists: Bool = false,
                                progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        try Task.checkCancellation()
        if let expectedTarget, currentTarget != expectedTarget { throw CancellationError() }
        let source = try requireBackend()
        return try await source.exportTableRows(query: query, descriptor: descriptor, to: destination, format: format,
                                                timeoutSeconds: timeoutSeconds, cancellation: cancellation,
                                                failIfExists: failIfExists, progress: progress)
    }

    public func importRows(into descriptor: EditableTableDescriptor, text: String, format: DataTransferFormat, expectedTarget: DatabaseTarget? = nil) async throws -> ImportRowsResult {
        try Task.checkCancellation()
        if let expectedTarget, currentTarget != expectedTarget { throw CancellationError() }
        let source = try requireBackend()
        return try await source.importRows(into: descriptor, text: text, format: format)
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
