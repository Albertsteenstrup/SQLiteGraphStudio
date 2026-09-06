@preconcurrency import GRDB
import Foundation

public struct CatalogSnapshot: Sendable {
    public let descriptors: [EditableTableDescriptor]
    public let graph: SchemaGraph
    public let recordRelationshipMetadata: [RecordRelationship]?

    public init(descriptors: [EditableTableDescriptor], graph: SchemaGraph, recordRelationshipMetadata: [RecordRelationship]? = nil) {
        self.descriptors = descriptors
        self.graph = graph
        self.recordRelationshipMetadata = recordRelationshipMetadata
    }
}

public actor SQLiteDatabaseBackend {
    var pool: DatabasePool?
    private var currentURL: URL?

    public init() {}

    public nonisolated var capabilities: DatabaseCapabilities {
        .sqlite
    }

    public func open(url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 3000")
        }

        pool = try DatabasePool(path: url.path, configuration: configuration)
        currentURL = url
        StudioLog.db.info("Opened database: \(url.lastPathComponent, privacy: .public)")
    }

    public func close() {
        pool = nil
        currentURL = nil
        StudioLog.db.info("Closed database")
    }

    public func listTables() throws -> [TableSummary] {
        try loadCatalogSnapshot().descriptors.map(\.summary)
    }

    public func loadSchemaGraph() throws -> SchemaGraph {
        try loadCatalogSnapshot().graph
    }

    public func loadCatalogSnapshot() throws -> CatalogSnapshot {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try StudioLog.dbSignposter.withIntervalSignpost("LoadCatalog") {
            try pool.read { db in
                let tableListRows = try Row.fetchAll(db, sql: "PRAGMA table_list")

                var descriptors: [EditableTableDescriptor] = []
                var edges: [GraphEdge] = []

                // First pass: collect all table descriptors and build unique-column sets
                // so that cardinality inference can look up target table uniqueness.
                struct TableBuildInfo {
                    let descriptor: EditableTableDescriptor
                    let uniqueColumns: Set<String>
                }
                var buildInfos: [TableBuildInfo] = []

                for tableRow in tableListRows {
                    let schema: String = tableRow["schema"]
                    guard schema == "main" else { continue }

                    let name: String = tableRow["name"]
                    guard !name.hasPrefix("sqlite_") else { continue }

                    let objectType = SQLiteObjectType(rawDatabaseType: (tableRow["type"] as String?) ?? "unknown")
                    let withoutRowID = ((tableRow["wr"] as Int?) ?? 0) != 0

                    let columns = try loadColumns(for: name, database: db)
                    let primaryKeyColumns = columns
                        .filter { $0.primaryKeyOrdinal > 0 }
                        .sorted { $0.primaryKeyOrdinal < $1.primaryKeyOrdinal }
                        .map(\.name)
                    let rowCount = try loadRowCount(for: name, objectType: objectType, database: db)
                    let indexes = try loadIndexes(for: name, database: db)
                    let triggers = try loadTriggers(for: name, database: db)
                    let generatedColumns = columns
                        .filter(\.isGenerated)
                        .map {
                            GeneratedColumnInfo(
                                name: $0.name,
                                declaredType: $0.declaredType,
                                storedKind: $0.hiddenValue == 3 ? "stored" : "virtual"
                            )
                        }
                    let tableSQL = try String.fetchOne(
                        db,
                        sql: "SELECT sql FROM sqlite_schema WHERE name = ?",
                        arguments: [name]
                    )

                    let rowIdentityStrategy: RowIdentityStrategy
                    let isEditable: Bool

                    if objectType == .table && !primaryKeyColumns.isEmpty {
                        rowIdentityStrategy = .primaryKey
                        isEditable = true
                    } else if objectType == .table && !withoutRowID {
                        rowIdentityStrategy = .rowID
                        isEditable = true
                    } else {
                        rowIdentityStrategy = .readOnly
                        isEditable = false
                    }

                    let descriptor = EditableTableDescriptor(
                        name: name,
                        objectType: objectType,
                        columns: columns,
                        primaryKeyColumns: primaryKeyColumns,
                        rowIdentityStrategy: rowIdentityStrategy,
                        isWithoutRowID: withoutRowID,
                        isEditable: isEditable,
                        rowCount: rowCount,
                        indexes: indexes,
                        triggers: triggers,
                        constraints: try loadConstraints(
                            for: name,
                            columns: columns,
                            primaryKeyColumns: primaryKeyColumns,
                            indexes: indexes,
                            tableSQL: tableSQL,
                            database: db
                        ),
                        generatedColumns: generatedColumns
                    )
                    descriptors.append(descriptor)

                    let tableUniqueColumns = uniqueColumnSet(primaryKeyColumns: primaryKeyColumns, indexes: indexes)
                    buildInfos.append(TableBuildInfo(descriptor: descriptor, uniqueColumns: tableUniqueColumns))
                }

                // Build a lookup dictionary: tableName → unique column set
                let uniqueColumnsByTable: [String: Set<String>] = Dictionary(
                    uniqueKeysWithValues: buildInfos.map { ($0.descriptor.name, $0.uniqueColumns) }
                )

                // Second pass: load foreign keys with cardinality inference
                for info in buildInfos {
                    guard info.descriptor.objectType == .table else { continue }
                    edges.append(contentsOf: try loadForeignKeys(
                        for: info.descriptor.name,
                        sourceUniqueColumns: info.uniqueColumns,
                        uniqueColumnsByTable: uniqueColumnsByTable,
                        database: db
                    ))
                }

                let graphNodes = descriptors
                    .filter { $0.objectType == .table }
                    .map { GraphNode(id: $0.name, title: $0.name, isEditable: $0.isEditable) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

                let graph = SchemaGraph(nodes: graphNodes, edges: edges)
                return CatalogSnapshot(
                    descriptors: descriptors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                    graph: graph
                )
            }
        }

        let elapsed = start.duration(to: clock.now).milliseconds
        StudioLog.db.info("Loaded schema snapshot in \(elapsed, format: .fixed(precision: 2)) ms")
        return snapshot
    }

    public func fetchDescriptor(named tableName: String) throws -> EditableTableDescriptor {
        guard let descriptor = try loadCatalogSnapshot().descriptors.first(where: { $0.name == tableName }) else {
            throw SQLiteUserError(kind: .notFound, message: "Table \(tableName) was not found.")
        }
        return descriptor
    }

    public func fetchChunk(query: TableQueryState, descriptor: EditableTableDescriptor) async throws -> TableChunk {
        guard query.limit >= 0, query.offset >= 0, query.offset <= Int.max - 10_001 else { throw DatabaseUserError(kind: .invalidInput, message: "Invalid page bounds.") }
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        var page = query
        page.limit = min(query.limit, 10_000) + 1
        let queryPlan = try makeQueryPlan(query: page, descriptor: descriptor)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try await pool.read { db in
                let exactCount = query.requestExactCount ? try Int.fetchOne(db, sql: queryPlan.countSQL, arguments: queryPlan.countArguments) : query.cachedExactCount
                let rows = try Row.fetchAll(db, sql: queryPlan.selectSQL, arguments: queryPlan.selectArguments)
                let limit = min(query.limit, 10_000)
                let countState = TableCountState.forPage(query: query, rowCount: min(rows.count, limit), hasMore: rows.count > limit, exactCount: exactCount)
                return TableChunk(
                    rows: rows.prefix(limit).map { row in
                        let rowValues = descriptor.columns.map { column in
                            let dbValue: DatabaseValue = row[column.name]
                            return SQLiteValue(databaseValue: dbValue)
                        }

                        let identity: TableRowIdentity
                        switch descriptor.rowIdentityStrategy {
                        case .primaryKey:
                            let components = descriptor.primaryKeyColumns.map { columnName in
                                IdentityComponent(
                                    columnName: columnName,
                                    value: SQLiteValue(databaseValue: row[columnName])
                                )
                            }
                            identity = .primaryKey(components)
                        case .rowID:
                            let rowID: Int64 = row["__sgs_rowid__"]
                            identity = .rowID(rowID)
                        case .readOnly:
                            let components = descriptor.fallbackSortColumns.map { columnName in
                                IdentityComponent(
                                    columnName: columnName,
                                    value: SQLiteValue(databaseValue: row[columnName])
                                )
                            }
                            identity = .primaryKey(components)
                        }

                        return TableRow(identity: identity, values: rowValues)
                    },
                    totalRowCount: max(countState.navigationCount, query.offset + min(rows.count, limit) + (rows.count > limit ? 1 : 0)),
                    offset: query.offset,
                    limit: limit,
                    countState: countState, hasMore: rows.count > limit
                )
        }

        let elapsed = startedAt.duration(to: clock.now).milliseconds
        StudioLog.db.info(
            "Fetched \(result.rows.count, privacy: .public) rows from \(descriptor.name, privacy: .public) in \(elapsed, format: .fixed(precision: 2)) ms"
        )
        return result
    }

    public func fetchRecords(descriptor: TableDescriptor, predicates: [IdentityComponent], offset: Int = 0, limit: Int = 50) async throws -> RecordPage {
        let plan = try RecordAccess.plan(descriptor: descriptor, predicates: predicates, offset: offset, limit: limit, postgres: false)
        return try await executeRecordPlan(plan)
    }

    public func fetchRelated(record: RecordSnapshot, relationship: RecordRelationship, direction: RecordDirection, offset: Int = 0, limit: Int = 50) async throws -> RecordPage {
        do {
            guard let plan = try RecordAccess.relatedPlan(record: record, relationship: relationship, direction: direction, offset: offset, limit: limit, postgres: false) else { return .empty(.nullReference) }
            return try await executeRecordPlan(plan, missingReference: direction == .outgoing)
        } catch RecordAccessError.unavailableTable {
            return .empty(.unavailable)
        }
    }

    private func executeRecordPlan(_ plan: RecordQueryPlan, missingReference: Bool = false) async throws -> RecordPage {
        try Task.checkCancellation()
        guard let pool else { throw SQLiteUserError(kind: .generic, message: "No database is open.") }
        let values = try await pool.read { db in
            try db.readOnly {
                try Row.fetchAll(db, sql: plan.sql, arguments: StatementArguments(plan.parameters.map(\.databaseValue)))
                    .map { row in (0..<row.count).map { SQLiteValue(databaseValue: row[$0] as DatabaseValue) } }
            }
        }
        try Task.checkCancellation()
        return try RecordAccess.page(values: values, plan: plan, missingReference: missingReference)
    }

    public func commitEdit(_ change: CellEditChange) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        let column = change.descriptor.columns.first(where: { $0.name == change.columnName })
        guard let column else {
            throw SQLiteUserError(kind: .invalidInput, message: "Unknown column \(change.columnName).")
        }

        guard change.descriptor.isEditable, column.isEditable else {
            throw SQLiteUserError(kind: .readOnly, message: "This value cannot be edited.")
        }

        let parsedValue = try parseSQLiteValue(change.rawValue, for: column)
        let statement = try updateStatement(for: change, newValue: parsedValue)

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try StudioLog.dbSignposter.withIntervalSignpost("CommitEdit") {
                try pool.writeWithoutTransaction { db in
                    try db.inTransaction {
                        try db.execute(
                            sql: statement.sql,
                            arguments: statement.arguments
                        )
                        if db.changesCount == 0 {
                            throw SQLiteUserError(kind: .notFound, message: "The selected row no longer exists.")
                        }
                        return .commit
                    }
                }
            }
            let elapsed = startedAt.duration(to: clock.now).milliseconds
            StudioLog.db.info(
                "Committed edit on \(change.descriptor.name, privacy: .public).\(change.columnName, privacy: .public) in \(elapsed, format: .fixed(precision: 2)) ms"
            )
        } catch {
            let mapped = SQLiteUserError.from(error)
            StudioLog.db.error(
                "Edit failed for \(change.descriptor.name, privacy: .public).\(change.columnName, privacy: .public): \(mapped.message, privacy: .public)"
            )
            throw mapped
        }
    }

    public func insertDefaultRow(into descriptor: EditableTableDescriptor) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        guard descriptor.isEditable else {
            throw SQLiteUserError(kind: .readOnly, message: "Rows can only be added to editable tables.")
        }

        do {
            try pool.writeWithoutTransaction { db in
                try db.inTransaction {
                    let requiredColumns = descriptor.columns.filter { column in
                        column.isEditable
                            && column.defaultValueSQL == nil
                            && (column.notNull || column.primaryKeyOrdinal > 0)
                            && !(column.primaryKeyOrdinal == 1 && column.affinity == .integer && descriptor.primaryKeyColumns.count == 1)
                    }

                    if requiredColumns.isEmpty {
                        try db.execute(sql: "INSERT INTO \(quoteIdentifier(descriptor.name)) DEFAULT VALUES")
                    } else {
                        var arguments = StatementArguments()
                        for column in requiredColumns {
                            arguments += [emptyInsertValue(for: column).databaseValue]
                        }
                        try db.execute(
                            sql: """
                            INSERT INTO \(quoteIdentifier(descriptor.name)) (\(requiredColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")))
                            VALUES (\(Array(repeating: "?", count: requiredColumns.count).joined(separator: ", ")))
                            """,
                            arguments: arguments
                        )
                    }
                    return .commit
                }
            }
        } catch {
            throw SQLiteUserError.from(error)
        }
    }

    public func insertClonedRow(from sourceRow: TableRow, into descriptor: EditableTableDescriptor) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        guard descriptor.isEditable else {
            throw SQLiteUserError(kind: .readOnly, message: "Rows can only be cloned in editable tables.")
        }

        let columnsToClone = cloneableColumns(from: descriptor)

        do {
            try pool.writeWithoutTransaction { db in
                try db.inTransaction {
                    if columnsToClone.isEmpty {
                        try db.execute(sql: "INSERT INTO \(quoteIdentifier(descriptor.name)) DEFAULT VALUES")
                    } else {
                        var arguments = StatementArguments()
                        for column in columnsToClone {
                            if let index = descriptor.columns.firstIndex(where: { $0.name == column.name }) {
                                arguments += [sourceRow.values[index].databaseValue]
                            }
                        }
                        let columnNames = columnsToClone.map { quoteIdentifier($0.name) }.joined(separator: ", ")
                        let placeholders = Array(repeating: "?", count: columnsToClone.count).joined(separator: ", ")
                        try db.execute(
                            sql: "INSERT INTO \(quoteIdentifier(descriptor.name)) (\(columnNames)) VALUES (\(placeholders))",
                            arguments: arguments
                        )
                    }
                    return .commit
                }
            }
        } catch {
            throw SQLiteUserError.from(error)
        }
    }

    public func deleteRow(_ identity: TableRowIdentity, from descriptor: EditableTableDescriptor) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }
        guard descriptor.isEditable else {
            throw SQLiteUserError(kind: .readOnly, message: "Rows can only be deleted from editable tables.")
        }

        var predicates: [String] = []
        var arguments = StatementArguments()
        switch identity {
        case .rowID(let rowID):
            predicates.append("_rowid_ = ?")
            arguments += [rowID]
        case .primaryKey(let components):
            for component in components {
                if component.value == .null {
                    predicates.append("\(quoteIdentifier(component.columnName)) IS NULL")
                } else {
                    predicates.append("\(quoteIdentifier(component.columnName)) = ?")
                    arguments += [component.value.databaseValue]
                }
            }
        }
        guard !predicates.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "The selected row has no delete identity.")
        }

        let sql = "DELETE FROM \(quoteIdentifier(descriptor.name)) WHERE \(predicates.joined(separator: " AND "))"
        do {
            try pool.writeWithoutTransaction { db in
                try db.inTransaction {
                    try db.execute(sql: sql, arguments: arguments)
                    if db.changesCount == 0 {
                        throw SQLiteUserError(kind: .notFound, message: "The selected row no longer exists.")
                    }
                    return .commit
                }
            }
        } catch {
            throw SQLiteUserError.from(error)
        }
    }

    public func dropColumn(columnName: String, from descriptor: EditableTableDescriptor) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }
        guard descriptor.objectType == .table else {
            throw SQLiteUserError(kind: .readOnly, message: "Columns can only be dropped from tables.")
        }
        guard let column = descriptor.columns.first(where: { $0.name == columnName }) else {
            throw SQLiteUserError(kind: .notFound, message: "Column \(columnName) was not found.")
        }
        guard column.canDropInSQLite else {
            throw SQLiteUserError(kind: .readOnly, message: "Column \(columnName) cannot be dropped safely.")
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try StudioLog.dbSignposter.withIntervalSignpost("DropColumn") {
                try pool.writeWithoutTransaction { db in
                    try db.inTransaction {
                        try db.execute(
                            sql: """
                            ALTER TABLE \(quoteIdentifier(descriptor.name))
                            DROP COLUMN \(quoteIdentifier(columnName))
                            """
                        )
                        return .commit
                    }
                }
            }
            let elapsed = startedAt.duration(to: clock.now).milliseconds
            StudioLog.db.info(
                "Dropped column \(columnName, privacy: .public) from \(descriptor.name, privacy: .public) in \(elapsed, format: .fixed(precision: 2)) ms"
            )
        } catch {
            let mapped = SQLiteUserError.from(error)
            StudioLog.db.error(
                "Drop column failed for \(descriptor.name, privacy: .public).\(columnName, privacy: .public): \(mapped.message, privacy: .public)"
            )
            throw mapped
        }
    }

    public func createTable(_ draft: TableCreateDraft) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        let sql = try makeCreateTableSQL(draft)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: sql)
        }
    }

    public func renameTable(from currentName: String, to newName: String) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Enter a table name.")
        }

        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "ALTER TABLE \(quoteIdentifier(currentName)) RENAME TO \(quoteIdentifier(trimmedName))")
        }
    }

    public func addColumn(_ draft: TableColumnDraft, to descriptor: EditableTableDescriptor) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }
        guard descriptor.objectType == .table else {
            throw SQLiteUserError(kind: .readOnly, message: "Columns can only be added to tables.")
        }
        let columnSQL = try makeColumnDefinitionSQL(draft, primaryKeyMode: .none)
        guard !draft.isPrimaryKey else {
            throw SQLiteUserError(kind: .invalidInput, message: "SQLite cannot add a primary-key column with ALTER TABLE.")
        }

        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "ALTER TABLE \(quoteIdentifier(descriptor.name)) ADD COLUMN \(columnSQL)")
        }
    }

    public func renameColumn(from currentName: String, to newName: String, in descriptor: EditableTableDescriptor) throws {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }
        guard descriptor.objectType == .table else {
            throw SQLiteUserError(kind: .readOnly, message: "Columns can only be renamed on tables.")
        }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Enter a column name.")
        }

        try pool.writeWithoutTransaction { db in
            try db.execute(
                sql: """
                ALTER TABLE \(quoteIdentifier(descriptor.name))
                RENAME COLUMN \(quoteIdentifier(currentName)) TO \(quoteIdentifier(trimmedName))
                """
            )
        }
    }

    public func executeReadOnlyQuery(sql rawSQL: String, rowLimit: Int = 500, timeoutSeconds: TimeInterval = 30) async throws -> QueryResult {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        let sql = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Enter a SQL query first.")
        }

        let normalized = sql
            .replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let allowedPrefixes = ["SELECT", "WITH", "PRAGMA", "EXPLAIN"]
        guard allowedPrefixes.contains(where: { normalized.hasPrefix($0) }) else {
            throw SQLiteUserError(
                kind: .readOnly,
                message: "Query mode only allows SELECT, WITH, PRAGMA, or EXPLAIN statements."
            )
        }

        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = try await withQueryTimeout(seconds: timeoutSeconds) {
            try await pool.read { db in
                let statement = try db.makeStatement(sql: sql)
                let columnNames = statement.columnNames
                let cursor = try Row.fetchCursor(statement)

                var rows: [QueryResultRow] = []
                var inferredTypes = Array(repeating: "", count: columnNames.count)
                var truncated = false
                var index = 0

                while let row = try cursor.next() {
                    if rows.count >= rowLimit {
                        truncated = true
                        break
                    }

                    let values = columnNames.indices.map { columnIndex in
                        SQLiteValue(databaseValue: row[columnIndex])
                    }

                    for valueIndex in values.indices where inferredTypes[valueIndex].isEmpty && values[valueIndex] != .null {
                        inferredTypes[valueIndex] = values[valueIndex].typeLabel
                    }

                    rows.append(QueryResultRow(id: index, values: values))
                    index += 1
                }

                let columns = columnNames.enumerated().map { index, name in
                    QueryResultColumn(
                        name: name,
                        typeLabel: inferredTypes[index].isEmpty ? "UNKNOWN" : inferredTypes[index]
                    )
                }

                return QueryResult(
                    columns: columns,
                    rows: rows,
                    isTruncated: truncated,
                    rowLimit: rowLimit
                )
            }
        }

        let elapsed = startedAt.duration(to: clock.now).milliseconds
        StudioLog.db.info("Executed SQL query in \(elapsed, format: .fixed(precision: 2)) ms")
        return result
    }

    public func explainQueryPlan(sql rawSQL: String, timeoutSeconds: TimeInterval = 30) async throws -> [ExplainPlanRow] {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        let sql = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Enter a SQL query first.")
        }

        let normalized = sql
            .replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let allowedPrefixes = ["SELECT", "WITH", "PRAGMA", "EXPLAIN"]
        guard allowedPrefixes.contains(where: { normalized.hasPrefix($0) }) else {
            throw SQLiteUserError(kind: .readOnly, message: "Explain mode only allows SELECT, WITH, PRAGMA, or EXPLAIN statements.")
        }

        let planSQL = normalized.hasPrefix("EXPLAIN") ? sql : "EXPLAIN QUERY PLAN \(sql)"
        return try await withQueryTimeout(seconds: timeoutSeconds) {
            try await pool.read { db in
            try Row.fetchAll(db, sql: planSQL).map { row in
                ExplainPlanRow(
                    id: row["id"] ?? 0,
                    parent: row["parent"] ?? 0,
                    notUsed: row["notused"] ?? 0,
                    detail: row["detail"] ?? ""
                )
            }
            }
        }
    }

    public func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) throws -> String {
        try ResultSerialization.serializeQueryResult(result, format: format)
    }

    public func serializeTableRows(descriptor: EditableTableDescriptor, rows: [TableRow], format: DataTransferFormat) throws -> String {
        try ResultSerialization.serializeTableRows(descriptor: descriptor, rows: rows, format: format)
    }

    public func importRows(into descriptor: EditableTableDescriptor, text: String, format: DataTransferFormat) throws -> ImportRowsResult {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }
        guard descriptor.isEditable else {
            throw SQLiteUserError(kind: .readOnly, message: "Rows can only be imported into editable tables.")
        }

        let rows = try parseImportRows(text: text, format: format)
        guard !rows.isEmpty else {
            return ImportRowsResult(insertedRowCount: 0, skippedRowCount: 0, messages: ["No rows found."])
        }

        let editableColumns = Dictionary(uniqueKeysWithValues: descriptor.columns.filter(\.isEditable).map { ($0.name, $0) })
        var inserted = 0
        var skipped = 0
        var messages: [String] = []

        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                for (rowIndex, row) in rows.enumerated() {
                    let pairs = row
                        .compactMap { key, value -> (TableColumn, String?)? in
                            guard let column = editableColumns[key] else { return nil }
                            return (column, value)
                        }
                        .sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }

                    guard !pairs.isEmpty else {
                        skipped += 1
                        messages.append("Row \(rowIndex + 1) has no importable columns.")
                        continue
                    }

                    do {
                        var arguments = StatementArguments()
                        for (column, value) in pairs {
                            if let value {
                                // Import parsers already distinguish SQL NULL from
                                // text, including quoted CSV and JSON string values.
                                arguments += [try parseSQLiteValue(value, for: column, recognizesNullLiteral: false).databaseValue]
                            } else {
                                arguments += [DatabaseValue.null]
                            }
                        }

                        let sql = """
                        INSERT INTO \(quoteIdentifier(descriptor.name)) (\(pairs.map { quoteIdentifier($0.0.name) }.joined(separator: ", ")))
                        VALUES (\(Array(repeating: "?", count: pairs.count).joined(separator: ", ")))
                        """
                        try db.execute(sql: sql, arguments: arguments)
                        inserted += 1
                    } catch {
                        skipped += 1
                        messages.append("Row \(rowIndex + 1): \(SQLiteUserError.from(error).message)")
                    }
                }
                return .commit
            }
        }

        return ImportRowsResult(insertedRowCount: inserted, skippedRowCount: skipped, messages: Array(messages.prefix(8)))
    }

    public nonisolated func makeCreateTableSQL(_ draft: TableCreateDraft) throws -> String {
        let tableName = draft.tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tableName.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Enter a table name.")
        }

        let columns = draft.columns.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !columns.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Add at least one column.")
        }

        let primaryColumns = columns.filter(\.isPrimaryKey)
        let primaryKeyMode: PrimaryKeyDefinitionMode = primaryColumns.count == 1 ? .inline : .tableConstraint
        var definitions = try columns.map { try makeColumnDefinitionSQL($0, primaryKeyMode: primaryKeyMode) }
        if primaryColumns.count > 1 {
            definitions.append("PRIMARY KEY (\(primaryColumns.map { quoteIdentifier($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }.joined(separator: ", ")))")
        }

        return """
        CREATE TABLE \(quoteIdentifier(tableName)) (
            \(definitions.joined(separator: ",\n    "))
        )
        """
    }

    private func loadColumns(for tableName: String, database db: Database) throws -> [TableColumn] {
        try Row.fetchAll(db, sql: "PRAGMA table_xinfo(\(quoteStringLiteral(tableName)))").compactMap { row in
            let name: String = row["name"]
            guard !name.isEmpty else { return nil }
            return TableColumn(
                name: name,
                declaredType: (row["type"] as String?) ?? "",
                notNull: ((row["notnull"] as Int?) ?? 0) != 0,
                defaultValueSQL: row["dflt_value"],
                primaryKeyOrdinal: (row["pk"] as Int?) ?? 0,
                hiddenValue: (row["hidden"] as Int?) ?? 0
            )
        }
    }

    private func loadRowCount(for objectName: String, objectType: SQLiteObjectType, database db: Database) throws -> Int? {
        guard objectType == .table || objectType == .view else { return nil }
        do {
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoteIdentifier(objectName))")
        } catch {
            return nil
        }
    }

    private func loadIndexes(for tableName: String, database db: Database) throws -> [SchemaIndex] {
        try Row.fetchAll(db, sql: "PRAGMA index_list(\(quoteStringLiteral(tableName)))").map { row in
            let name: String = row["name"]
            let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(\(quoteStringLiteral(name)))")
                .map { indexRow -> String in
                    let columnName: String? = indexRow["name"]
                    return columnName ?? ""
                }
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?", arguments: [name])
            return SchemaIndex(
                name: name,
                columns: columns,
                isUnique: ((row["unique"] as Int?) ?? 0) != 0,
                origin: (row["origin"] as String?) ?? "",
                isPartial: ((row["partial"] as Int?) ?? 0) != 0,
                sql: sql
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func loadTriggers(for tableName: String, database db: Database) throws -> [SchemaTrigger] {
        try Row.fetchAll(
            db,
            sql: "SELECT name, tbl_name, sql FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = ? ORDER BY name",
            arguments: [tableName]
        )
        .compactMap { row in
            guard let sql: String = row["sql"] else { return nil }
            return SchemaTrigger(name: row["name"], tableName: row["tbl_name"], sql: sql)
        }
    }

    private func loadConstraints(
        for tableName: String,
        columns: [TableColumn],
        primaryKeyColumns: [String],
        indexes: [SchemaIndex],
        tableSQL: String?,
        database db: Database
    ) throws -> [SchemaConstraint] {
        var constraints: [SchemaConstraint] = []

        if !primaryKeyColumns.isEmpty {
            constraints.append(
                SchemaConstraint(
                    id: "\(tableName).pk",
                    kind: .primaryKey,
                    columns: primaryKeyColumns,
                    detail: "PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))"
                )
            )
        }

        for column in columns {
            if column.notNull {
                constraints.append(
                    SchemaConstraint(
                        id: "\(tableName).\(column.name).not-null",
                        kind: .notNull,
                        columns: [column.name],
                        detail: "\(column.name) NOT NULL"
                    )
                )
            }
            if let defaultValueSQL = column.defaultValueSQL {
                constraints.append(
                    SchemaConstraint(
                        id: "\(tableName).\(column.name).default",
                        kind: .defaultValue,
                        columns: [column.name],
                        detail: "\(column.name) DEFAULT \(defaultValueSQL)"
                    )
                )
            }
        }

        for index in indexes where index.isUnique {
            constraints.append(
                SchemaConstraint(
                    id: "\(tableName).unique.\(index.name)",
                    kind: .unique,
                    name: index.name,
                    columns: index.columns,
                    detail: "UNIQUE (\(index.columns.joined(separator: ", ")))"
                )
            )
        }

        let foreignKeyRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quoteStringLiteral(tableName)))")
        let groupedForeignKeys = Dictionary(grouping: foreignKeyRows) { row in
            (row["id"] as Int?) ?? 0
        }
        for (identifier, rows) in groupedForeignKeys.sorted(by: { $0.key < $1.key }) {
            let orderedRows = rows.sorted { lhs, rhs in
                ((lhs["seq"] as Int?) ?? 0) < ((rhs["seq"] as Int?) ?? 0)
            }
            let sourceColumns = orderedRows.map { ($0["from"] as String?) ?? "" }.filter { !$0.isEmpty }
            let targetTable = (orderedRows.first?["table"] as String?) ?? ""
            let targetColumns = orderedRows.map { ($0["to"] as String?) ?? "" }.filter { !$0.isEmpty }
            constraints.append(
                SchemaConstraint(
                    id: "\(tableName).fk.\(identifier)",
                    kind: .foreignKey,
                    columns: sourceColumns,
                    detail: "FOREIGN KEY (\(sourceColumns.joined(separator: ", "))) REFERENCES \(targetTable)(\(targetColumns.joined(separator: ", ")))"
                )
            )
        }

        for (index, checkSQL) in checkConstraintDetails(in: tableSQL ?? "").enumerated() {
            constraints.append(
                SchemaConstraint(
                    id: "\(tableName).check.\(index)",
                    kind: .check,
                    columns: [],
                    detail: checkSQL
                )
            )
        }

        return constraints
    }

    private func loadForeignKeys(
        for tableName: String,
        sourceUniqueColumns: Set<String>,
        uniqueColumnsByTable: [String: Set<String>],
        database db: Database
    ) throws -> [GraphEdge] {
        let sourceColumns = try loadColumns(for: tableName, database: db)
        return try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quoteStringLiteral(tableName)))").map { row in
            let identifier: Int = (row["id"] as Int?) ?? 0
            let sequence: Int = (row["seq"] as Int?) ?? 0
            let declaredTarget: String = row["table"]
            let targetTable = uniqueColumnsByTable.keys.first { RecordAccess.sqliteIdentifierMatches($0, declaredTarget) } ?? declaredTarget
            let declaredSource: String = row["from"]
            let fromColumn = sourceColumns.first { RecordAccess.sqliteIdentifierMatches($0.name, declaredSource) }?.name ?? declaredSource
            let explicitTarget: String? = row["to"]
            let targetColumns = try loadColumns(for: targetTable, database: db)
            let targetPK = targetColumns.filter { $0.primaryKeyOrdinal > 0 }
                .sorted { $0.primaryKeyOrdinal < $1.primaryKeyOrdinal }
            let toColumn = explicitTarget.map { declared in
                targetColumns.first { RecordAccess.sqliteIdentifierMatches($0.name, declared) }?.name ?? declared
            } ?? (targetPK.indices.contains(sequence) ? targetPK[sequence].name : "")
            let targetUniqueColumns = uniqueColumnsByTable[targetTable]
            let cardinality = inferCardinality(
                sourceColumn: fromColumn,
                targetColumn: toColumn,
                sourceUniqueColumns: sourceUniqueColumns,
                targetUniqueColumns: targetUniqueColumns
            )
            return GraphEdge(
                id: "\(tableName)->\(targetTable)#\(identifier):\(sequence)",
                sourceID: tableName,
                targetID: targetTable,
                sourceColumn: fromColumn,
                targetColumn: toColumn,
                cardinality: cardinality
            )
        }
    }

    /// Infers the cardinality of a foreign key relationship based on whether the source and target
    /// columns are covered by unique constraints (primary key or single-column unique index).
    /// Defaults to `.manyToOne` when target table index info is unavailable.
    private func inferCardinality(
        sourceColumn: String,
        targetColumn: String,
        sourceUniqueColumns: Set<String>,
        targetUniqueColumns: Set<String>?
    ) -> EdgeCardinality {
        let sourceUnique = sourceUniqueColumns.contains(sourceColumn)
        // Default to treating target as unique (manyToOne) when info is unavailable
        let targetUnique = targetUniqueColumns.map { $0.contains(targetColumn) } ?? true
        return inferEdgeCardinality(sourceUnique: sourceUnique, targetUnique: targetUnique)
    }

    /// Computes the set of columns that are considered "unique" for cardinality inference:
    /// a single-column primary key plus columns that are the sole column in a unique index.
    ///
    /// Composite primary keys are intentionally excluded: each component column is not
    /// unique on its own (only the combination is), so columns from a multi-column PK
    /// must not be treated as unique here. Without this guard, junction tables with
    /// composite PKs incorrectly resolve to 1:1 edges with their parents instead of N:1.
    private func uniqueColumnSet(primaryKeyColumns: [String], indexes: [SchemaIndex]) -> Set<String> {
        var unique = Set<String>()
        if primaryKeyColumns.count == 1 {
            unique.insert(primaryKeyColumns[0])
        }
        for index in indexes where index.isUnique && index.columns.count == 1 {
            unique.insert(index.columns[0])
        }
        return unique
    }

    func makeQueryPlan(query: TableQueryState, descriptor: EditableTableDescriptor) throws -> QueryPlan {
        let plan = try PostgresTableQueryBuilder.makePlan(query: query, descriptor: descriptor, dialect: .sqlite)
        func arguments(_ parameters: [PostgresQueryParameter]) -> StatementArguments {
            StatementArguments(parameters.map { parameter -> DatabaseValue in
                switch parameter {
                case .null: return .null
                case .text(let value): return value.databaseValue
                case .integer(let value): return value.databaseValue
                case .double(let value): return value.databaseValue
                case .boolean(let value): return value.databaseValue
                case .bytes(let value): return value.databaseValue
                }
            })
        }
        return QueryPlan(countSQL: plan.countSQL, countArguments: arguments(Array(plan.countParameters)), selectSQL: plan.selectSQL, selectArguments: arguments(plan.parameters))
    }

    private func updateStatement(for change: CellEditChange, newValue: SQLiteValue) throws -> QueryStatement {
        var arguments = StatementArguments()
        arguments += [newValue.databaseValue]

        var predicates: [String] = []
        switch change.rowIdentity {
        case .rowID(let rowID):
            predicates.append("_rowid_ = ?")
            arguments += [rowID]
        case .primaryKey(let components):
            for component in components {
                if component.value == .null {
                    predicates.append("\(quoteIdentifier(component.columnName)) IS NULL")
                } else {
                    predicates.append("\(quoteIdentifier(component.columnName)) = ?")
                    arguments += [component.value.databaseValue]
                }
            }
        }

        guard !predicates.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "The selected row has no update identity.")
        }

        let sql = """
        UPDATE \(quoteIdentifier(change.descriptor.name))
        SET \(quoteIdentifier(change.columnName)) = ?
        WHERE \(predicates.joined(separator: " AND "))
        """

        return QueryStatement(sql: sql, arguments: arguments)
    }

    private func emptyInsertValue(for column: TableColumn) -> SQLiteValue {
        switch column.affinity {
        case .integer:
            return .integer(0)
        case .real:
            return .double(0)
        case .numeric:
            return .integer(0)
        case .blob:
            return .blob(Data())
        case .text, .none:
            if column.primaryKeyOrdinal > 0 {
                return .text(UUID().uuidString)
            }
            return .text("")
        }
    }

    private enum PrimaryKeyDefinitionMode {
        case none
        case inline
        case tableConstraint
    }

    private nonisolated func makeColumnDefinitionSQL(_ draft: TableColumnDraft, primaryKeyMode: PrimaryKeyDefinitionMode) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SQLiteUserError(kind: .invalidInput, message: "Enter a column name.")
        }

        var fragments = [quoteIdentifier(name)]
        let type = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
        if !type.isEmpty {
            fragments.append(type)
        }
        if draft.isPrimaryKey, primaryKeyMode == .inline {
            fragments.append("PRIMARY KEY")
        }
        if draft.isNotNull {
            fragments.append("NOT NULL")
        }
        let defaultSQL = draft.defaultValueSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultSQL.isEmpty {
            fragments.append("DEFAULT \(defaultSQL)")
        }

        return fragments.joined(separator: " ")
    }
}

/// Maps a pair of uniqueness flags to an `EdgeCardinality` value.
///
/// This is the core inference rule for foreign key cardinality:
/// - `(true, true)`  → `.oneToOne`   (source unique, target unique)
/// - `(true, false)` → `.oneToMany`  (source unique, target not unique)
/// - `(false, true)` → `.manyToOne`  (source not unique, target unique)
/// - `(false, false)` → `.manyToMany` (neither unique)
///
/// **Validates: Requirements 1.2, 1.3, 1.4, 1.5, 1.6**
func inferEdgeCardinality(sourceUnique: Bool, targetUnique: Bool) -> EdgeCardinality {
    switch (sourceUnique, targetUnique) {
    case (true, true):   return .oneToOne
    case (true, false):  return .oneToMany
    case (false, true):  return .manyToOne
    case (false, false): return .manyToMany
    }
}

struct QueryPlan {
    let countSQL: String
    let countArguments: StatementArguments
    let selectSQL: String
    let selectArguments: StatementArguments
}

private struct QueryStatement {
    let sql: String
    let arguments: StatementArguments
}

private extension SQLiteValue {
    var exportText: String {
        switch self {
        case .null:
            return ""
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .exactNumeric(let value):
            return value
        case .text(let value):
            return value
        case .uuid(let value), .dateTime(let value), .json(let value), .array(let value):
            return value
        case .blob(let data):
            return data.base64EncodedString()
        }
    }

    var jsonObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .integer(let value):
            return value
        case .double(let value):
            return value
        case .boolean(let value):
            return value
        case .exactNumeric(let value):
            return value
        case .text(let value):
            return value
        case .uuid(let value), .dateTime(let value):
            return value
        case .json(let value), .array(let value):
            if let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
            return value
        case .blob(let data):
            return data.base64EncodedString()
        }
    }
}

private func serializeCSV(rows: [[String]]) -> String {
    rows
        .map { row in
            row.map(escapeCSVField).joined(separator: ",")
        }
        .joined(separator: "\n")
}

private func escapeCSVField(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
        return value
    }

    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func serializeJSONObject(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func parseImportRows(text: String, format: DataTransferFormat) throws -> [[String: String?]] {
    switch format {
    case .csv:
        let records = parseCSVRecords(text)
        guard let header = records.first, !header.isEmpty else { return [] }
        return records.dropFirst().map { record in
            var row: [String: String?] = [:]
            for (index, columnName) in header.enumerated() {
                let trimmedName = columnName.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                guard record.indices.contains(index) else {
                    row.updateValue(nil, forKey: trimmedName)
                    continue
                }
                let field = record[index]
                let legacyNull = field.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "NULL"
                let isNull = !field.isQuoted && (field.text == "\\N" || legacyNull)
                row.updateValue(isNull ? nil : field.text, forKey: trimmedName)
            }
            return row
        }
    case .json:
        guard let data = text.data(using: .utf8) else {
            throw SQLiteUserError(kind: .invalidInput, message: "The JSON content is not valid UTF-8.")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any] {
            rows = [dictionary]
        } else {
            throw SQLiteUserError(kind: .invalidInput, message: "JSON import expects an object or an array of objects.")
        }

        return rows.map { row in
            row.reduce(into: [String: String?]()) { partial, pair in
                partial.updateValue(importText(from: pair.value), forKey: pair.key)
            }
        }
    }
}

private func importText(from value: Any) -> String? {
    if value is NSNull {
        return nil
    }
    if let value = value as? String {
        return value
    }
    if let value = value as? Bool {
        return value ? "1" : "0"
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return String(describing: value)
}

private struct CSVImportField {
    let text: String
    let isQuoted: Bool
}

private func parseCSVRecords(_ text: String) -> [[CSVImportField]] {
    var records: [[CSVImportField]] = []
    var record: [CSVImportField] = []
    var field = ""
    var isInQuotes = false
    var fieldIsQuoted = false
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let nextIndex = text.index(after: index)

        if character == "\"" {
            fieldIsQuoted = true
            if isInQuotes, nextIndex < text.endIndex, text[nextIndex] == "\"" {
                field.append("\"")
                index = text.index(after: nextIndex)
                continue
            }
            isInQuotes.toggle()
        } else if character == ",", !isInQuotes {
            record.append(CSVImportField(text: field, isQuoted: fieldIsQuoted))
            field = ""
            fieldIsQuoted = false
        } else if (character == "\n" || character == "\r" || character == "\r\n"), !isInQuotes {
            if character == "\r", nextIndex < text.endIndex, text[nextIndex] == "\n" {
                index = nextIndex
            }
            record.append(CSVImportField(text: field, isQuoted: fieldIsQuoted))
            records.append(record)
            record = []
            field = ""
            fieldIsQuoted = false
        } else {
            field.append(character)
        }

        index = text.index(after: index)
    }

    if !field.isEmpty || !record.isEmpty || fieldIsQuoted {
        record.append(CSVImportField(text: field, isQuoted: fieldIsQuoted))
        records.append(record)
    }

    return records.filter { row in
        row.contains { $0.isQuoted || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private func checkConstraintDetails(in sql: String) -> [String] {
    let uppercased = sql.uppercased()
    var results: [String] = []
    var searchStart = uppercased.startIndex

    while let checkRange = uppercased.range(of: "CHECK", range: searchStart..<uppercased.endIndex),
          let openParen = uppercased[checkRange.upperBound...].firstIndex(of: "(") {
        var depth = 0
        var current = openParen
        var closeParen: String.Index?

        while current < uppercased.endIndex {
            let character = uppercased[current]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    closeParen = current
                    break
                }
            }
            current = uppercased.index(after: current)
        }

        if let closeParen {
            results.append(String(sql[checkRange.lowerBound...closeParen]))
            searchStart = uppercased.index(after: closeParen)
        } else {
            break
        }
    }

    return results
}
