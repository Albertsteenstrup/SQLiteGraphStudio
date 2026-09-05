@preconcurrency import GRDB
import Foundation
import Logging
import PostgresNIO

extension SQLiteDatabaseBackend {
    public func exportTableRows(query: TableQueryState, descriptor: TableDescriptor, to destination: URL, format: DataTransferFormat,
                                timeoutSeconds: TimeInterval = 300, cancellation: ExportCancellation = ExportCancellation(),
                                progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        guard let pool else { throw DatabaseUserError(kind: .generic, message: "No database is open.") }
        var snapshotQuery = query
        snapshotQuery.offset = 0
        snapshotQuery.after = nil
        snapshotQuery.limit = Int.max
        let plan = try makeQueryPlan(query: snapshotQuery, descriptor: descriptor)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let writer = try AtomicRowExportWriter(destination: destination, names: descriptor.columns.map(\.name), format: format, cancellation: cancellation)
            defer { writer.abort() }
            try await withQueryTimeout(seconds: timeoutSeconds) {
                try await withTaskCancellationHandler {
                    try await pool.read { db in
                        progress(0)
                        let cursor = try Row.fetchCursor(db, sql: plan.selectSQL, arguments: plan.selectArguments)
                        while let row = try cursor.next() {
                            try writer.append(descriptor.columns.indices.map { SQLiteValue(databaseValue: row[$0]) })
                            if writer.rowCount % 128 == 0 { progress(writer.rowCount) }
                        }
                        try cancellation.check()
                    }
                } onCancel: { cancellation.cancel() }
            }
            try Task.checkCancellation()
            progress(writer.rowCount)
            return try writer.finish()
        } onCancel: { cancellation.cancel() }
    }
}

extension PostgresDatabaseBackend {
    public func exportTableRows(query: TableQueryState, descriptor: TableDescriptor, to destination: URL, format: DataTransferFormat,
                                timeoutSeconds: TimeInterval = 300, cancellation: ExportCancellation = ExportCancellation(),
                                progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        var snapshotQuery = query
        snapshotQuery.offset = 0
        snapshotQuery.after = nil
        snapshotQuery.limit = Int.max
        let plan = try PostgresTableQueryBuilder.makePlan(query: snapshotQuery, descriptor: descriptor)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let writer = try AtomicRowExportWriter(destination: destination, names: descriptor.columns.map(\.name), format: format, cancellation: cancellation)
            defer { writer.abort() }
            try await withReadOnlyTransaction(timeoutSeconds: timeoutSeconds) { connection in
                progress(0)
                let sequence = try await connection.query(PostgresQuery(unsafeSQL: plan.selectSQL, binds: try Self.bindings(plan.parameters)), logger: Logger(label: "SQLiteGraphStudio.Export"))
                for try await row in sequence {
                    try Task.checkCancellation()
                    let values = row.makeRandomAccess()
                    try writer.append((0..<values.count).map { PostgresValueMapper.map(values[data: $0]) })
                    if writer.rowCount % 128 == 0 { progress(writer.rowCount) }
                }
            }
            try Task.checkCancellation()
            progress(writer.rowCount)
            return try writer.finish()
        } onCancel: { cancellation.cancel() }
    }
}
