@preconcurrency import GRDB
import Foundation

struct CatalogSnapshot: Sendable {
    let descriptors: [EditableTableDescriptor]
    let graph: SchemaGraph
}

public actor DatabaseService {
    private var pool: DatabasePool?
    private var currentURL: URL?

    public init() {}

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

    func loadCatalogSnapshot() throws -> CatalogSnapshot {
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
                        isEditable: isEditable
                    )
                    descriptors.append(descriptor)

                    guard objectType == .table else { continue }
                    edges.append(contentsOf: try loadForeignKeys(for: name, database: db))
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

    public func fetchChunk(query: TableQueryState, descriptor: EditableTableDescriptor) throws -> TableChunk {
        guard let pool else {
            throw SQLiteUserError(kind: .generic, message: "No database is open.")
        }

        let queryPlan = makeQueryPlan(query: query, descriptor: descriptor)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try StudioLog.dbSignposter.withIntervalSignpost("FetchChunk") {
            try pool.read { db in
                let totalRowCount = try Int.fetchOne(db, sql: queryPlan.countSQL, arguments: queryPlan.countArguments) ?? 0
                let rows = try Row.fetchAll(db, sql: queryPlan.selectSQL, arguments: queryPlan.selectArguments)
                return TableChunk(
                    rows: rows.map { row in
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
                    totalRowCount: totalRowCount,
                    offset: query.offset,
                    limit: query.limit
                )
            }
        }

        let elapsed = startedAt.duration(to: clock.now).milliseconds
        StudioLog.db.info(
            "Fetched \(result.rows.count, privacy: .public) rows from \(descriptor.name, privacy: .public) in \(elapsed, format: .fixed(precision: 2)) ms"
        )
        return result
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

    public func executeReadOnlyQuery(sql rawSQL: String, rowLimit: Int = 500) throws -> QueryResult {
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

        let result = try StudioLog.dbSignposter.withIntervalSignpost("ExecuteQuery") {
            try pool.read { db in
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

                    let values = columnNames.map { columnName in
                        SQLiteValue(databaseValue: row[columnName])
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

    private func loadForeignKeys(for tableName: String, database db: Database) throws -> [GraphEdge] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quoteStringLiteral(tableName)))").map { row in
            let identifier: Int = (row["id"] as Int?) ?? 0
            let sequence: Int = (row["seq"] as Int?) ?? 0
            let targetTable: String = row["table"]
            let fromColumn: String = row["from"]
            let toColumn: String = row["to"]
            return GraphEdge(
                id: "\(tableName)->\(targetTable)#\(identifier):\(sequence)",
                sourceID: tableName,
                targetID: targetTable,
                sourceColumn: fromColumn,
                targetColumn: toColumn
            )
        }
    }

    private func makeQueryPlan(query: TableQueryState, descriptor: EditableTableDescriptor) -> QueryPlan {
        var conditions: [String] = []
        var arguments = StatementArguments()

        let searchText = query.sanitizedSearchText
        if !searchText.isEmpty, !descriptor.searchableColumns.isEmpty {
            let pattern = "%\(searchText)%"
            let searchSQL = descriptor.searchableColumns
                .map { "CAST(\(quoteIdentifier($0.name)) AS TEXT) LIKE ?" }
                .joined(separator: " OR ")
            conditions.append("(\(searchSQL))")
            descriptor.searchableColumns.forEach { _ in
                arguments += [pattern]
            }
        }

        for filter in query.sanitizedFilters {
            conditions.append("CAST(\(quoteIdentifier(filter.columnName)) AS TEXT) LIKE ?")
            arguments += ["%\(filter.value)%"]
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")

        var orderTerms: [String] = []
        if let sort = query.sort {
            orderTerms.append("\(quoteIdentifier(sort.columnName)) \(sort.direction.sqlKeyword)")
        }

        for fallback in descriptor.fallbackSortColumns where !orderTerms.contains(where: { $0.contains(quoteIdentifier(fallback)) }) {
            if fallback == "_rowid_" {
                orderTerms.append("_rowid_ ASC")
            } else {
                orderTerms.append("\(quoteIdentifier(fallback)) ASC")
            }
        }

        let orderClause = orderTerms.isEmpty ? "" : " ORDER BY " + orderTerms.joined(separator: ", ")

        let selectedColumns = descriptor.columns.map { quoteIdentifier($0.name) }
        var projection = selectedColumns
        if descriptor.rowIdentityStrategy == .rowID {
            projection.append("_rowid_ AS __sgs_rowid__")
        }

        let countSQL = "SELECT COUNT(*) FROM \(quoteIdentifier(descriptor.name))\(whereClause)"
        var selectArguments = arguments
        selectArguments += [query.limit, query.offset]

        let selectSQL = """
        SELECT \(projection.joined(separator: ", "))
        FROM \(quoteIdentifier(descriptor.name))\(whereClause)\(orderClause)
        LIMIT ? OFFSET ?
        """

        return QueryPlan(
            countSQL: countSQL,
            countArguments: arguments,
            selectSQL: selectSQL,
            selectArguments: selectArguments
        )
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
}

private struct QueryPlan {
    let countSQL: String
    let countArguments: StatementArguments
    let selectSQL: String
    let selectArguments: StatementArguments
}

private struct QueryStatement {
    let sql: String
    let arguments: StatementArguments
}
