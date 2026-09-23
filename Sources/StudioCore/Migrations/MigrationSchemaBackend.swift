import Foundation

/// Serves a schema reconstructed from migration files. The model describes
/// structure only: there is no database behind it, so every row-level and
/// mutating operation fails closed with an explanation.
public actor MigrationSchemaBackend {
    private var model: MigrationSchemaModel?

    public init() {}

    public nonisolated var capabilities: DatabaseCapabilities { .migrationsSchemaOnly }

    public func open(set: MigrationSet, through version: String?,
                     progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        let files = set.files(through: version)
        guard !files.isEmpty else {
            throw DatabaseUserError(kind: .invalidInput, message: "This migration folder has no SQL files to replay.")
        }
        await progress("Reading \(files.count) migration\(files.count == 1 ? "" : "s")…")

        let dialect = set.dialect
        let reported = ReplayProgressThrottle(total: files.count, report: progress)
        model = try await BackgroundWork.run {
            try MigrationSchemaReplay.buildModel(files: files, dialect: dialect) { step in
                reported.report(step)
            }
        }
    }

    public func close() {
        model = nil
    }

    public var schemaModel: MigrationSchemaModel? { model }

    private func requireModel() throws -> MigrationSchemaModel {
        guard let model else { throw DatabaseUserError(kind: .generic, message: "No migration model is open.") }
        return model
    }

    private func schemaOnlyError(_ message: String) -> DatabaseUserError {
        DatabaseUserError(
            kind: .readOnly,
            message: message,
            recoverySuggestion: "This model is reconstructed from migration files, so it has structure but no data. Open a database file or a PostgreSQL connection to browse rows."
        )
    }
}

/// Coalesces per-file progress into occasional messages so a 400-file replay
/// does not post hundreds of main-actor updates.
private final class ReplayProgressThrottle: @unchecked Sendable {
    private let total: Int
    private let report: @Sendable (String) async -> Void
    private let lock = NSLock()
    private var lastReported = -1

    init(total: Int, report: @escaping @Sendable (String) async -> Void) {
        self.total = total
        self.report = report
    }

    func report(_ progress: MigrationSchemaReplay.Progress) {
        let step = max(1, total / 20)
        let shouldReport: Bool = lock.withLock {
            guard progress.completedFiles >= lastReported + step || progress.completedFiles == total else { return false }
            lastReported = progress.completedFiles
            return true
        }
        guard shouldReport else { return }
        let message = "Replaying migrations… \(progress.completedFiles) of \(total)"
        let report = report
        Task { await report(message) }
    }
}

extension MigrationSchemaBackend: DatabaseBackend {
    public func listTables() async throws -> [TableSummary] {
        try requireModel().catalog.descriptors.map(\.summary)
    }

    public func loadSchemaGraph() async throws -> SchemaGraph {
        try requireModel().catalog.graph
    }

    public func loadCatalogSnapshot() async throws -> CatalogSnapshot {
        try requireModel().catalog
    }

    public func fetchDescriptor(named tableName: String) async throws -> EditableTableDescriptor {
        guard let descriptor = try requireModel().catalog.descriptors.first(where: { $0.name == tableName }) else {
            throw DatabaseUserError(kind: .notFound, message: "‘\(tableName)’ is not in this migration model.")
        }
        return descriptor
    }

    public func fetchChunk(query: TableQueryState, descriptor: EditableTableDescriptor) async throws -> TableChunk {
        _ = try requireModel()
        throw schemaOnlyError("Rows cannot be browsed in a migration model.")
    }

    public func readBoundedCell(query: TableQueryState, descriptor: EditableTableDescriptor, columnName: String,
                                offset: Int, length: Int,
                                expectedRowIdentity: TableRowIdentity?) async throws -> BoundedCellRead? {
        _ = try requireModel()
        throw schemaOnlyError("Cell values cannot be read from a migration model.")
    }

    public func withBoundedCellReadSnapshot<T: Sendable>(
        query: TableQueryState,
        descriptor: EditableTableDescriptor,
        columnName: String,
        expectedRowIdentity: TableRowIdentity?,
        operation: @escaping @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> T
    ) async throws -> T {
        _ = try requireModel()
        throw schemaOnlyError("Cell values cannot be read from a migration model.")
    }

    public func fetchRecords(descriptor: TableDescriptor, predicates: [IdentityComponent],
                             offset: Int, limit: Int) async throws -> RecordPage {
        throw schemaOnlyError("Records cannot be inspected in a migration model.")
    }

    public func fetchRelated(record: RecordSnapshot, relationship: RecordRelationship,
                             direction: RecordDirection, offset: Int, limit: Int) async throws -> RecordPage {
        throw schemaOnlyError("Related records cannot be followed in a migration model.")
    }

    public func commitEdit(_ change: CellEditChange) async throws {
        throw schemaOnlyError("Values cannot be edited in a migration model.")
    }

    public func insertDefaultRow(into descriptor: EditableTableDescriptor) async throws {
        throw schemaOnlyError("Rows cannot be added to a migration model.")
    }

    public func insertClonedRow(from sourceRow: TableRow, into descriptor: EditableTableDescriptor) async throws {
        throw schemaOnlyError("Rows cannot be cloned in a migration model.")
    }

    public func deleteRow(_ identity: TableRowIdentity, from descriptor: EditableTableDescriptor) async throws {
        throw schemaOnlyError("Rows cannot be deleted in a migration model.")
    }

    public func dropColumn(columnName: String, from descriptor: EditableTableDescriptor) async throws {
        throw schemaOnlyError("A migration model is read-only; edit the migration files instead.")
    }

    public func createTable(_ draft: TableCreateDraft) async throws {
        throw schemaOnlyError("A migration model is read-only; add a migration file instead.")
    }

    public func renameTable(from currentName: String, to newName: String) async throws {
        throw schemaOnlyError("A migration model is read-only; add a migration file instead.")
    }

    public func addColumn(_ draft: TableColumnDraft, to descriptor: EditableTableDescriptor) async throws {
        throw schemaOnlyError("A migration model is read-only; add a migration file instead.")
    }

    public func renameColumn(from currentName: String, to newName: String,
                             in descriptor: EditableTableDescriptor) async throws {
        throw schemaOnlyError("A migration model is read-only; add a migration file instead.")
    }

    public func executeReadOnlyQuery(sql: String, rowLimit: Int, timeoutSeconds: TimeInterval) async throws -> QueryResult {
        throw schemaOnlyError("SQL cannot run against a migration model.")
    }

    public func explainQueryPlan(sql: String, timeoutSeconds: TimeInterval) async throws -> [ExplainPlanRow] {
        throw schemaOnlyError("SQL cannot run against a migration model.")
    }

    public func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) async throws -> String {
        throw schemaOnlyError("A migration model has no query results to export.")
    }

    public func serializeTableRows(descriptor: EditableTableDescriptor, rows: [TableRow],
                                   format: DataTransferFormat) async throws -> String {
        throw schemaOnlyError("A migration model has no rows to export.")
    }

    public func exportTableRows(query: TableQueryState, descriptor: TableDescriptor, to destination: URL,
                                format: DataTransferFormat, timeoutSeconds: TimeInterval,
                                cancellation: ExportCancellation,
                                failIfExists: Bool,
                                progress: @escaping @Sendable (Int) -> Void) async throws -> Int {
        _ = try requireModel()
        throw schemaOnlyError("A migration model has no rows to export.")
    }

    public func importRows(into descriptor: EditableTableDescriptor, text: String,
                           format: DataTransferFormat) async throws -> ImportRowsResult {
        throw schemaOnlyError("Rows cannot be imported into a migration model.")
    }
}
