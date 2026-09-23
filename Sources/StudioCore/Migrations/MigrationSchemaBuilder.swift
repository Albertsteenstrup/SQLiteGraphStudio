import Foundation

/// Replays the DDL in an ordered migration set to reconstruct the schema those
/// migrations would produce. Only structure is tracked — no rows are evaluated.
///
/// Every statement it cannot interpret is recorded as a diagnostic rather than
/// being silently dropped, so the resulting model always says what it missed.
final class MigrationSchemaBuilder {
    private let dialect: SQLDialect

    private var tables: [String: MigrationTable] = [:]
    private var indexes: [String: MigrationIndex] = [:]
    private var triggers: [String: MigrationTrigger] = [:]
    private var partitionChildCounts: [String: Int] = [:]
    /// Objects a migration creates for its own use and drops again. They are not
    /// part of the data model, and later statements about them are not errors.
    private var temporaryKeys: Set<String> = []
    private var searchPathSchema: String?

    private var diagnostics: [MigrationDiagnostic] = []
    private var diagnosticIdentifiers: Set<String> = []
    private var fileName = ""
    private(set) var statementCount = 0

    private static let diagnosticLimit = 250

    /// Keywords that end a type name or a DEFAULT expression inside a column
    /// definition. Multi-word types (`double precision`, `timestamp with time
    /// zone`, `character varying`) are unaffected because their continuation
    /// words are not listed here.
    private static let columnConstraintKeywords: Set<String> = [
        "NOT", "NULL", "PRIMARY", "UNIQUE", "DEFAULT", "REFERENCES", "CHECK",
        "GENERATED", "COLLATE", "CONSTRAINT", "DEFERRABLE", "INITIALLY",
        "AUTOINCREMENT", "ON", "STORAGE", "COMPRESSION", "IDENTITY", "AS",
    ]

    private static let ignoredStatementKeywords: Set<String> = [
        "BEGIN", "COMMIT", "END", "ROLLBACK", "START", "SAVEPOINT", "RELEASE",
        "INSERT", "UPDATE", "DELETE", "SELECT", "WITH", "VALUES", "TRUNCATE",
        "GRANT", "REVOKE", "ANALYZE", "ANALYSE", "VACUUM", "REFRESH", "PRAGMA",
        "NOTIFY", "LISTEN", "UNLISTEN", "EXPLAIN", "CALL", "COPY", "PREPARE",
        "EXECUTE", "DEALLOCATE", "LOCK", "CLUSTER", "REINDEX", "RESET",
        "DECLARE", "FETCH", "CLOSE", "MERGE", "IF", "RAISE", "PERFORM", "RETURN",
        "INSERT_INTO", "SECURITY", "DISCARD", "CHECKPOINT", "SHOW", "ATTACH", "DETACH",
    ]

    init(dialect: SQLDialect) {
        self.dialect = dialect
        self.searchPathSchema = dialect.defaultSchema
    }

    // MARK: - Entry points

    func apply(sql: String, fileName: String) {
        self.fileName = fileName
        for statement in SQLScript.statements(in: sql) {
            statementCount += 1
            var cursor = SQLCursor(SQLStatementTokens(statement))
            dispatch(&cursor, depth: 0)
        }
    }

    private func dispatch(_ cursor: inout SQLCursor, depth: Int) {
        guard let first = cursor.peek(), first.kind == .word else { return }
        switch first.upper {
        case "CREATE":
            applyCreate(&cursor)
        case "ALTER":
            applyAlter(&cursor)
        case "DROP":
            applyDrop(&cursor)
        case "COMMENT":
            applyComment(&cursor)
        case "DO":
            applyDoBlock(&cursor, depth: depth)
        case "SET":
            applySet(&cursor)
        default:
            if !Self.ignoredStatementKeywords.contains(first.upper) {
                note("unrecognised statement", cursor)
            }
        }
    }

    // MARK: - DO blocks

    /// PL/pgSQL guards such as `if not exists (…) then alter table … end if` wrap
    /// otherwise ordinary DDL. The guard exists to make the statement idempotent,
    /// so applying the DDL unconditionally reproduces the same end state.
    private func applyDoBlock(_ cursor: inout SQLCursor, depth: Int) {
        guard depth == 0 else { return }
        var scan = cursor
        scan.advance()
        _ = scan.match("LANGUAGE")
        var body: String?
        while let token = scan.peek() {
            if token.kind == .string { body = token.text; break }
            scan.advance()
        }
        guard let body else { return }

        var appliedAny = false
        for chunk in SQLScript.statements(in: body) {
            let stream = SQLStatementTokens(chunk)
            guard let start = Self.embeddedDDLStart(in: stream) else { continue }
            var embedded = SQLCursor(stream, at: start)
            dispatch(&embedded, depth: depth + 1)
            appliedAny = true
        }
        if !appliedAny, body.range(of: #"(?is)\b(create|alter|drop)\s+(table|index|constraint)\b"#,
                                   options: .regularExpression) != nil {
            note("DDL inside this block could not be replayed", cursor)
        }
    }

    private static let ddlVerbs: Set<String> = ["CREATE", "ALTER", "DROP"]
    private static let ddlObjects: Set<String> = [
        "TABLE", "INDEX", "VIEW", "MATERIALIZED", "UNIQUE", "TRIGGER", "CONSTRAINT", "OR", "SCHEMA",
    ]
    /// Tokens a statement can legitimately follow inside a PL/pgSQL body. This
    /// keeps a `drop`/`create` word appearing inside a guard expression from
    /// being mistaken for the start of a statement.
    private static let ddlPredecessors: Set<String> = ["THEN", "ELSE", "BEGIN", "LOOP", "DECLARE", "DO"]

    private static func embeddedDDLStart(in stream: SQLStatementTokens) -> Int? {
        for (index, token) in stream.tokens.enumerated() {
            guard token.kind == .word, ddlVerbs.contains(token.upper) else { continue }
            guard let next = stream.tokens[safe: index + 1], next.kind == .word,
                  ddlObjects.contains(next.upper) else { continue }
            if index == 0 { return index }
            let previous = stream.tokens[index - 1]
            if previous.kind == .word, ddlPredecessors.contains(previous.upper) { return index }
            if previous.kind == .symbol, previous.text == ";" { return index }
        }
        return nil
    }

    // MARK: - SET

    private func applySet(_ cursor: inout SQLCursor) {
        cursor.advance()
        _ = cursor.match("SESSION") || cursor.match("LOCAL")
        guard cursor.match("SEARCH_PATH") else { return }
        _ = cursor.match("TO") || cursor.matchSymbol("=")
        for piece in cursor.splitTopLevel(cursor.remaining) {
            guard let token = cursor.stream.tokens[safe: piece.lowerBound] else { continue }
            let candidate = token.text.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate != "$user", candidate.lowercased() != "pg_catalog" else { continue }
            searchPathSchema = dialect.fold(candidate, quoted: token.kind != .word)
            return
        }
    }

    // MARK: - CREATE

    private func applyCreate(_ cursor: inout SQLCursor) {
        cursor.advance()
        _ = cursor.match(["OR", "REPLACE"])
        var isUnique = false
        var isMaterialized = false
        var isTemporary = false
        decorations: while let keyword = cursor.peekKeyword() {
            switch keyword {
            case "TEMP", "TEMPORARY":
                isTemporary = true
                cursor.advance()
            case "GLOBAL", "LOCAL", "UNLOGGED", "RECURSIVE", "CONSTRAINT":
                cursor.advance()
            case "UNIQUE":
                isUnique = true
                cursor.advance()
            case "MATERIALIZED":
                isMaterialized = true
                cursor.advance()
            default:
                break decorations
            }
        }

        switch cursor.peekKeyword() {
        case "TABLE":
            cursor.advance()
            createTable(&cursor, isTemporary: isTemporary)
        case "VIEW":
            cursor.advance()
            createView(&cursor, objectType: isMaterialized ? .materializedView : .view,
                       isTemporary: isTemporary)
        case "INDEX":
            cursor.advance()
            createIndex(&cursor, isUnique: isUnique)
        case "TRIGGER":
            cursor.advance()
            createTrigger(&cursor)
        default:
            // Functions, types, extensions, sequences, schemas, policies and
            // roles do not take part in the table graph.
            break
        }
    }

    private func createTable(_ cursor: inout SQLCursor, isTemporary: Bool) {
        cursor.matchExistenceGuard()
        guard let name = readObjectName(&cursor) else {
            note("could not read the table name", cursor)
            return
        }
        let key = objectKey(name)
        guard !isTemporary, name.schema?.lowercased() != "pg_temp" else {
            temporaryKeys.insert(key)
            return
        }
        var table = MigrationTable(schema: name.schema, objectName: name.name, objectType: .table)

        if cursor.match(["PARTITION", "OF"]) {
            if let parent = readObjectName(&cursor) {
                let parentKey = objectKey(parent)
                if let parentTable = tables[parentKey] {
                    table.columns = parentTable.columns
                    table.primaryKey = parentTable.primaryKey.map {
                        MigrationKeyConstraint(name: "\(name.name)_pkey", columns: $0.columns)
                    }
                    table.partitionParentKey = parentKey
                    partitionChildCounts[parentKey, default: 0] += 1
                } else {
                    note("partition parent ‘\(parent.name)’ is unknown", cursor)
                }
            }
        } else if let elements = cursor.readParenthesizedRange() {
            parseTableElements(elements, cursor: cursor, table: &table)
            resolveUnattachedChecks(in: &table)
        } else if cursor.peekKeyword() == "AS" {
            note("CREATE TABLE … AS is not replayed, so ‘\(name.name)’ has no columns", cursor)
        } else if cursor.peekKeyword() == "OF" {
            note("typed tables are not replayed, so ‘\(name.name)’ has no columns", cursor)
        }

        while !cursor.isAtEnd {
            switch cursor.peekKeyword() {
            case "PARTITION":
                table.objectType = .partitionedTable
                cursor.advance()
            case "WITHOUT":
                cursor.advance()
                _ = cursor.match("ROWID")
                table.isWithoutRowID = true
            case "INHERITS":
                cursor.advance()
                if let parents = cursor.readParenthesizedRange() {
                    for piece in cursor.splitTopLevel(parents) {
                        var parentCursor = SQLCursor(cursor.stream, range: piece)
                        guard let parent = readObjectName(&parentCursor),
                              let parentTable = tables[objectKey(parent)] else { continue }
                        let known = Set(table.columns.map { $0.name.lowercased() })
                        table.columns.insert(contentsOf: parentTable.columns.filter {
                            !known.contains($0.name.lowercased())
                        }, at: 0)
                        partitionChildCounts[objectKey(parent), default: 0] += 1
                    }
                }
            default:
                cursor.advance()
            }
        }

        tables[key] = table
    }

    private func parseTableElements(_ range: Range<Int>, cursor: SQLCursor, table: inout MigrationTable) {
        for element in cursor.splitTopLevel(range) {
            var elementCursor = SQLCursor(cursor.stream, range: element)
            var constraintName: String?
            if elementCursor.match("CONSTRAINT") {
                constraintName = readIdentifier(&elementCursor)
            }

            switch elementCursor.peekKeyword() {
            case "PRIMARY":
                parsePrimaryKey(&elementCursor, name: constraintName, table: &table)
            case "UNIQUE":
                parseUnique(&elementCursor, name: constraintName, table: &table)
            case "FOREIGN":
                parseForeignKey(&elementCursor, name: constraintName, table: &table)
            case "CHECK", "EXCLUDE":
                parseCheck(&elementCursor, name: constraintName, table: &table)
            case "LIKE":
                elementCursor.advance()
                if let source = readObjectName(&elementCursor), let sourceTable = tables[objectKey(source)] {
                    table.columns.append(contentsOf: sourceTable.columns)
                }
            default:
                if constraintName != nil {
                    note("unsupported table constraint in ‘\(table.objectName)’", elementCursor)
                } else {
                    parseColumnDefinition(&elementCursor, table: &table)
                }
            }
        }
    }

    // MARK: - Table constraints

    private func parsePrimaryKey(_ cursor: inout SQLCursor, name: String?, table: inout MigrationTable) {
        cursor.advance()
        _ = cursor.match("KEY")
        guard let range = cursor.readParenthesizedRange() else { return }
        let columns = keyColumns(in: range, cursor: cursor)
        guard !columns.isEmpty else { return }
        table.primaryKey = MigrationKeyConstraint(name: name ?? "\(table.objectName)_pkey", columns: columns)
    }

    private func parseUnique(_ cursor: inout SQLCursor, name: String?, table: inout MigrationTable) {
        cursor.advance()
        _ = cursor.match(["NULLS", "NOT", "DISTINCT"]) || cursor.match(["NULLS", "DISTINCT"])
        guard let range = cursor.readParenthesizedRange() else { return }
        let columns = keyColumns(in: range, cursor: cursor)
        guard !columns.isEmpty else { return }
        let constraintName = name ?? "\(table.objectName)_\(columns.joined(separator: "_"))_key"
        guard !table.uniques.contains(where: { $0.name.caseInsensitiveCompare(constraintName) == .orderedSame }) else { return }
        table.uniques.append(MigrationKeyConstraint(name: constraintName, columns: columns))
    }

    private func parseForeignKey(_ cursor: inout SQLCursor, name: String?, table: inout MigrationTable) {
        cursor.advance()
        _ = cursor.match("KEY")
        guard let sourceRange = cursor.readParenthesizedRange() else { return }
        let columns = keyColumns(in: sourceRange, cursor: cursor)
        guard cursor.match("REFERENCES"), let target = readObjectName(&cursor), !columns.isEmpty else { return }
        var targetColumns: [String] = []
        if let targetRange = cursor.readParenthesizedRange() {
            targetColumns = keyColumns(in: targetRange, cursor: cursor)
        }
        let actions = cursor.source(cursor.remaining)
        appendForeignKey(
            MigrationForeignKeyConstraint(
                name: name ?? "\(table.objectName)_\(columns.joined(separator: "_"))_fkey",
                columns: columns,
                targetKey: objectKey(target),
                targetColumns: targetColumns,
                actions: actions
            ),
            to: &table
        )
    }

    private func parseCheck(_ cursor: inout SQLCursor, name: String?, table: inout MigrationTable) {
        let keyword = cursor.peekKeyword() ?? "CHECK"
        let start = cursor.index
        cursor.advance()
        let expressionRange = cursor.readParenthesizedRange()
        let detail = cursor.source(start..<cursor.index)
        let columns = expressionRange.map { referencedColumns(in: $0, cursor: cursor, table: table) } ?? []
        let constraintName = name
            ?? "\(table.objectName)_\(columns.first ?? keyword.lowercased())_check"
        guard !table.checks.contains(where: { $0.name.caseInsensitiveCompare(constraintName) == .orderedSame }) else { return }
        table.checks.append(MigrationCheckConstraint(name: constraintName, columns: columns, detail: detail))
    }

    /// A table-level CHECK can be written before the columns it constrains.
    /// Once the whole element list is parsed, attach those by name.
    private func resolveUnattachedChecks(in table: inout MigrationTable) {
        guard table.checks.contains(where: { $0.columns.isEmpty }) else { return }
        let names = table.columns.map(\.name)
        table.checks = table.checks.map { check in
            guard check.columns.isEmpty else { return check }
            let referenced = names.filter { name in
                check.detail.range(
                    of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b",
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
            return MigrationCheckConstraint(name: check.name, columns: referenced, detail: check.detail)
        }
    }

    private func appendForeignKey(_ foreignKey: MigrationForeignKeyConstraint, to table: inout MigrationTable) {
        guard !table.foreignKeys.contains(where: { $0.name.caseInsensitiveCompare(foreignKey.name) == .orderedSame })
        else { return }
        table.foreignKeys.append(foreignKey)
    }

    // MARK: - Column definitions

    @discardableResult
    private func parseColumnDefinition(_ cursor: inout SQLCursor, table: inout MigrationTable) -> String? {
        guard let nameToken = cursor.peek(), nameToken.isIdentifier else {
            note("could not read a column definition in ‘\(table.objectName)’", cursor)
            return nil
        }
        cursor.advance()
        let columnName = dialect.fold(nameToken.text, quoted: nameToken.kind == .quotedIdentifier)

        let typeRange = cursor.consume { token in
            token.kind == .word && Self.columnConstraintKeywords.contains(token.upper)
        }
        var column = MigrationColumn(name: columnName, type: cursor.source(typeRange))

        var pendingConstraintName: String?
        while !cursor.isAtEnd {
            if cursor.match("CONSTRAINT") {
                pendingConstraintName = readIdentifier(&cursor)
                continue
            }
            if cursor.match(["NOT", "NULL"]) {
                column.notNull = true
                continue
            }
            if cursor.match("NULL") {
                column.notNull = false
                continue
            }
            if cursor.match(["PRIMARY", "KEY"]) {
                table.primaryKey = MigrationKeyConstraint(
                    name: pendingConstraintName ?? "\(table.objectName)_pkey",
                    columns: [columnName]
                )
                pendingConstraintName = nil
                _ = cursor.match("AUTOINCREMENT")
                continue
            }
            if cursor.match("UNIQUE") {
                let name = pendingConstraintName ?? "\(table.objectName)_\(columnName)_key"
                if !table.uniques.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    table.uniques.append(MigrationKeyConstraint(name: name, columns: [columnName]))
                }
                pendingConstraintName = nil
                continue
            }
            if cursor.match("DEFAULT") {
                let range = cursor.consume { token in
                    token.kind == .word && Self.columnConstraintKeywords.contains(token.upper)
                }
                let text = cursor.source(range)
                column.defaultSQL = text.isEmpty ? nil : text
                continue
            }
            if cursor.peekKeyword() == "CHECK" {
                let start = cursor.index
                cursor.advance()
                let expression = cursor.readParenthesizedRange()
                let detail = cursor.source(start..<cursor.index)
                let name = pendingConstraintName ?? "\(table.objectName)_\(columnName)_check"
                pendingConstraintName = nil
                if !table.checks.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    // The column being defined is not in `table` yet, so name it
                    // explicitly; anything else the expression mentions follows.
                    let referenced = expression.map { referencedColumns(in: $0, cursor: cursor, table: table) } ?? []
                    table.checks.append(MigrationCheckConstraint(
                        name: name,
                        columns: [columnName] + referenced.filter { $0.caseInsensitiveCompare(columnName) != .orderedSame },
                        detail: detail
                    ))
                }
                continue
            }
            if cursor.match("REFERENCES") {
                guard let target = readObjectName(&cursor) else { continue }
                var targetColumns: [String] = []
                if let range = cursor.readParenthesizedRange() {
                    targetColumns = keyColumns(in: range, cursor: cursor)
                }
                let actionsRange = cursor.consume { token in
                    token.kind == .word && Self.columnConstraintKeywords.contains(token.upper) && token.upper != "ON"
                }
                appendForeignKey(
                    MigrationForeignKeyConstraint(
                        name: pendingConstraintName ?? "\(table.objectName)_\(columnName)_fkey",
                        columns: [columnName],
                        targetKey: objectKey(target),
                        targetColumns: targetColumns,
                        actions: cursor.source(actionsRange)
                    ),
                    to: &table
                )
                pendingConstraintName = nil
                continue
            }
            if cursor.match("GENERATED") {
                if cursor.match("ALWAYS") {
                    if cursor.match("AS") {
                        if cursor.match("IDENTITY") {
                            column.identityKind = "a"
                            _ = cursor.readParenthesizedRange()
                        } else {
                            _ = cursor.readParenthesizedRange()
                            column.generatedKind = cursor.match("STORED") ? "stored" : "virtual"
                            _ = cursor.match("VIRTUAL")
                        }
                    }
                } else if cursor.match(["BY", "DEFAULT", "AS", "IDENTITY"]) {
                    column.identityKind = "d"
                    _ = cursor.readParenthesizedRange()
                }
                continue
            }
            if cursor.match("COLLATE") {
                cursor.advance()
                continue
            }
            if cursor.match("AUTOINCREMENT") { continue }
            // Storage hints, deferability and anything else this model does not
            // represent are skipped without complaint.
            cursor.advance()
        }

        if let existing = table.columnIndex(named: columnName) {
            table.columns[existing] = column
        } else {
            table.columns.append(column)
        }
        return columnName
    }

    // MARK: - Views

    private func createView(_ cursor: inout SQLCursor, objectType: SQLiteObjectType, isTemporary: Bool) {
        cursor.matchExistenceGuard()
        guard let name = readObjectName(&cursor) else { return }
        let key = objectKey(name)
        guard !isTemporary, name.schema?.lowercased() != "pg_temp" else {
            temporaryKeys.insert(key)
            return
        }
        var table = tables[key] ?? MigrationTable(schema: name.schema, objectName: name.name, objectType: objectType)
        table.objectType = objectType
        table.columns = []
        table.primaryKey = nil
        table.uniques = []
        table.checks = []
        table.foreignKeys = []

        if let declared = cursor.readParenthesizedRange() {
            table.columns = keyColumns(in: declared, cursor: cursor).map { MigrationColumn(name: $0, type: "") }
        }
        if table.columns.isEmpty, cursor.match("AS") {
            table.columns = ViewProjection.columns(from: &cursor, dialect: dialect).map {
                MigrationColumn(name: $0, type: "")
            }
        }
        tables[key] = table
    }

    // MARK: - Indexes and triggers

    private func createIndex(_ cursor: inout SQLCursor, isUnique: Bool) {
        _ = cursor.match("CONCURRENTLY")
        cursor.matchExistenceGuard()
        var declaredName: String?
        if cursor.peekKeyword() != "ON" {
            declaredName = readObjectName(&cursor)?.name
        }
        guard cursor.match("ON") else {
            note("could not read the indexed table", cursor)
            return
        }
        _ = cursor.match("ONLY")
        guard let tableName = readObjectName(&cursor) else { return }
        if cursor.match("USING") { cursor.advance() }
        guard let elements = cursor.readParenthesizedRange() else {
            note("could not read the index columns", cursor)
            return
        }
        let columns = keyColumns(in: elements, cursor: cursor, allowsExpressions: true)
        var isPartial = false
        while !cursor.isAtEnd {
            if cursor.peekKeyword() == "WHERE" { isPartial = true; break }
            cursor.advance()
        }
        guard !temporaryKeys.contains(objectKey(tableName)) else { return }
        let name = declaredName ?? "\(tableName.name)_\(columns.joined(separator: "_"))_idx"
        let key = objectKey((schema: tableName.schema, name: name))
        indexes[key] = MigrationIndex(
            name: name,
            tableKey: objectKey(tableName),
            columns: columns,
            isUnique: isUnique,
            isPartial: isPartial,
            sql: cursor.source(0..<cursor.stream.tokens.count)
        )
    }

    private func createTrigger(_ cursor: inout SQLCursor) {
        cursor.matchExistenceGuard()
        guard let name = readObjectName(&cursor) else { return }
        while !cursor.isAtEnd, !cursor.match("ON") { cursor.advance() }
        guard let tableName = readObjectName(&cursor) else { return }
        let tableKey = objectKey(tableName)
        guard !temporaryKeys.contains(tableKey) else { return }
        triggers["\(tableKey)|\(name.name.lowercased())"] = MigrationTrigger(
            name: name.name,
            tableKey: tableKey,
            sql: cursor.source(0..<cursor.stream.tokens.count)
        )
    }

    // MARK: - ALTER

    private func applyAlter(_ cursor: inout SQLCursor) {
        cursor.advance()
        if cursor.match("INDEX") {
            cursor.matchExistenceGuard()
            guard let current = readObjectName(&cursor), cursor.match(["RENAME", "TO"]),
                  let replacement = readObjectName(&cursor) else { return }
            guard var index = indexes.removeValue(forKey: objectKey(current)) else { return }
            index.name = replacement.name
            indexes[objectKey((schema: current.schema, name: replacement.name))] = index
            return
        }
        guard cursor.match("TABLE") else { return }
        cursor.matchExistenceGuard()
        _ = cursor.match("ONLY")
        guard let name = readObjectName(&cursor) else {
            note("could not read the altered table name", cursor)
            return
        }
        _ = cursor.matchSymbol("*")
        let key = objectKey(name)
        guard !temporaryKeys.contains(key) else { return }
        guard tables[key] != nil else {
            note("ALTER TABLE targets unknown table ‘\(name.name)’", cursor)
            return
        }

        if cursor.match("RENAME") {
            applyRename(&cursor, key: key)
            return
        }
        if cursor.match(["SET", "SCHEMA"]) {
            guard let schema = readIdentifier(&cursor), var table = tables.removeValue(forKey: key) else { return }
            table.schema = dialect == .sqlite ? nil : schema
            tables[objectKey((schema: table.schema, name: table.objectName))] = table
            return
        }

        for action in cursor.splitTopLevel(cursor.remaining) {
            var actionCursor = SQLCursor(cursor.stream, range: action)
            applyAlterAction(&actionCursor, key: key)
        }
    }

    private func applyRename(_ cursor: inout SQLCursor, key: String) {
        guard var table = tables[key] else { return }
        if cursor.match("TO") {
            guard let replacement = readObjectName(&cursor) else { return }
            tables.removeValue(forKey: key)
            let previousName = table.objectName
            table.objectName = replacement.name
            let newKey = objectKey((schema: table.schema, name: replacement.name))
            tables[newKey] = table
            retarget(from: key, to: newKey, previousName: previousName, newName: replacement.name)
            return
        }
        if cursor.match("CONSTRAINT") {
            guard let current = readIdentifier(&cursor), cursor.match("TO"),
                  let replacement = readIdentifier(&cursor) else { return }
            renameConstraint(from: current, to: replacement, in: &table)
            tables[key] = table
            return
        }
        _ = cursor.match("COLUMN")
        guard let current = readIdentifier(&cursor), cursor.match("TO"),
              let replacement = readIdentifier(&cursor) else { return }
        renameColumn(from: current, to: replacement, in: &table)
        tables[key] = table
        for (indexKey, var index) in indexes where index.tableKey == key {
            index.columns = index.columns.map {
                $0.caseInsensitiveCompare(current) == .orderedSame ? replacement : $0
            }
            indexes[indexKey] = index
        }
    }

    private func applyAlterAction(_ cursor: inout SQLCursor, key: String) {
        guard var table = tables[key] else { return }
        defer { tables[key] = table }

        switch cursor.peekKeyword() {
        case "ADD":
            cursor.advance()
            if cursor.match("COLUMN") {
                cursor.matchExistenceGuard()
                parseColumnDefinition(&cursor, table: &table)
                return
            }
            var constraintName: String?
            if cursor.match("CONSTRAINT") {
                cursor.matchExistenceGuard()
                constraintName = readIdentifier(&cursor)
            }
            switch cursor.peekKeyword() {
            case "PRIMARY":
                parsePrimaryKey(&cursor, name: constraintName, table: &table)
            case "UNIQUE":
                parseUnique(&cursor, name: constraintName, table: &table)
            case "FOREIGN":
                parseForeignKey(&cursor, name: constraintName, table: &table)
            case "CHECK", "EXCLUDE":
                parseCheck(&cursor, name: constraintName, table: &table)
            default:
                if constraintName == nil {
                    cursor.matchExistenceGuard()
                    parseColumnDefinition(&cursor, table: &table)
                } else {
                    note("unsupported ADD CONSTRAINT on ‘\(table.objectName)’", cursor)
                }
            }
        case "DROP":
            cursor.advance()
            if cursor.match("CONSTRAINT") {
                cursor.matchExistenceGuard()
                guard let name = readIdentifier(&cursor) else { return }
                dropConstraint(named: name, in: &table)
                return
            }
            _ = cursor.match("COLUMN")
            cursor.matchExistenceGuard()
            guard let name = readIdentifier(&cursor) else { return }
            dropColumn(named: name, in: &table, key: key)
        case "ALTER":
            cursor.advance()
            _ = cursor.match("COLUMN")
            alterColumn(&cursor, table: &table)
        case "OWNER", "ENABLE", "DISABLE", "VALIDATE", "CLUSTER", "SET", "RESET",
             "INHERIT", "NO", "ATTACH", "DETACH", "FORCE", "REPLICA", "OF", "NOT", "USING":
            break
        default:
            note("unsupported ALTER TABLE action on ‘\(table.objectName)’", cursor)
        }
    }

    private func alterColumn(_ cursor: inout SQLCursor, table: inout MigrationTable) {
        guard let name = readIdentifier(&cursor), let index = table.columnIndex(named: name) else { return }
        if cursor.match(["SET", "DATA", "TYPE"]) || cursor.match(["SET", "TYPE"]) || cursor.match("TYPE") {
            let range = cursor.consume { token in
                token.kind == .word && (token.upper == "USING" || token.upper == "COLLATE")
            }
            table.columns[index].type = cursor.source(range)
            return
        }
        if cursor.match(["SET", "NOT", "NULL"]) {
            table.columns[index].notNull = true
            return
        }
        if cursor.match(["DROP", "NOT", "NULL"]) {
            table.columns[index].notNull = false
            return
        }
        if cursor.match(["SET", "DEFAULT"]) {
            let text = cursor.source(cursor.remaining)
            table.columns[index].defaultSQL = text.isEmpty ? nil : text
            return
        }
        if cursor.match(["DROP", "DEFAULT"]) {
            table.columns[index].defaultSQL = nil
            return
        }
        if cursor.match(["DROP", "IDENTITY"]) {
            table.columns[index].identityKind = ""
            return
        }
        if cursor.match(["DROP", "EXPRESSION"]) {
            table.columns[index].generatedKind = ""
            return
        }
        if cursor.match(["ADD", "GENERATED"]) {
            table.columns[index].identityKind = cursor.match("ALWAYS") ? "a" : "d"
            return
        }
        // SET STATISTICS / SET STORAGE / SET COMPRESSION / SET (…) do not change
        // anything this model represents.
    }

    private func dropColumn(named name: String, in table: inout MigrationTable, key: String) {
        guard let index = table.columnIndex(named: name) else { return }
        table.columns.remove(at: index)
        func without(_ columns: [String]) -> Bool {
            columns.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if let primaryKey = table.primaryKey, without(primaryKey.columns) { table.primaryKey = nil }
        table.uniques.removeAll { without($0.columns) }
        table.checks.removeAll { without($0.columns) }
        table.foreignKeys.removeAll { without($0.columns) }
        for (indexKey, index) in indexes where index.tableKey == key && without(index.columns) {
            indexes.removeValue(forKey: indexKey)
        }
    }

    private func dropConstraint(named name: String, in table: inout MigrationTable) {
        func matches(_ candidate: String) -> Bool { candidate.caseInsensitiveCompare(name) == .orderedSame }
        if let primaryKey = table.primaryKey, matches(primaryKey.name) { table.primaryKey = nil }
        table.uniques.removeAll { matches($0.name) }
        table.checks.removeAll { matches($0.name) }
        table.foreignKeys.removeAll { matches($0.name) }
    }

    private func renameConstraint(from current: String, to replacement: String, in table: inout MigrationTable) {
        func rename(_ name: String) -> String {
            name.caseInsensitiveCompare(current) == .orderedSame ? replacement : name
        }
        if var primaryKey = table.primaryKey {
            primaryKey.name = rename(primaryKey.name)
            table.primaryKey = primaryKey
        }
        table.uniques = table.uniques.map { MigrationKeyConstraint(name: rename($0.name), columns: $0.columns) }
        table.checks = table.checks.map {
            MigrationCheckConstraint(name: rename($0.name), columns: $0.columns, detail: $0.detail)
        }
        table.foreignKeys = table.foreignKeys.map {
            MigrationForeignKeyConstraint(name: rename($0.name), columns: $0.columns,
                                          targetKey: $0.targetKey, targetColumns: $0.targetColumns, actions: $0.actions)
        }
    }

    private func renameColumn(from current: String, to replacement: String, in table: inout MigrationTable) {
        guard let index = table.columnIndex(named: current) else { return }
        table.columns[index].name = replacement
        func renamed(_ columns: [String]) -> [String] {
            columns.map { $0.caseInsensitiveCompare(current) == .orderedSame ? replacement : $0 }
        }
        if var primaryKey = table.primaryKey {
            primaryKey.columns = renamed(primaryKey.columns)
            table.primaryKey = primaryKey
        }
        table.uniques = table.uniques.map { MigrationKeyConstraint(name: $0.name, columns: renamed($0.columns)) }
        table.checks = table.checks.map {
            MigrationCheckConstraint(name: $0.name, columns: renamed($0.columns), detail: $0.detail)
        }
        table.foreignKeys = table.foreignKeys.map {
            MigrationForeignKeyConstraint(name: $0.name, columns: renamed($0.columns),
                                          targetKey: $0.targetKey, targetColumns: $0.targetColumns, actions: $0.actions)
        }
    }

    /// Keeps foreign keys pointing at a renamed table.
    private func retarget(from oldKey: String, to newKey: String, previousName: String, newName: String) {
        for (key, var table) in tables {
            var changed = false
            table.foreignKeys = table.foreignKeys.map { foreignKey in
                guard foreignKey.targetKey == oldKey else { return foreignKey }
                changed = true
                return MigrationForeignKeyConstraint(name: foreignKey.name, columns: foreignKey.columns,
                                                     targetKey: newKey, targetColumns: foreignKey.targetColumns,
                                                     actions: foreignKey.actions)
            }
            if changed { tables[key] = table }
        }
        for (indexKey, var index) in indexes where index.tableKey == oldKey {
            index.tableKey = newKey
            indexes[indexKey] = index
        }
        for (triggerKey, var trigger) in triggers where trigger.tableKey == oldKey {
            trigger.tableKey = newKey
            triggers.removeValue(forKey: triggerKey)
            triggers["\(newKey)|\(trigger.name.lowercased())"] = trigger
        }
        if let count = partitionChildCounts.removeValue(forKey: oldKey) {
            partitionChildCounts[newKey] = count
        }
    }

    // MARK: - DROP

    private func applyDrop(_ cursor: inout SQLCursor) {
        cursor.advance()
        switch cursor.peekKeyword() {
        case "TABLE", "VIEW":
            cursor.advance()
            cursor.matchExistenceGuard()
            dropObjects(&cursor)
        case "MATERIALIZED":
            cursor.advance()
            _ = cursor.match("VIEW")
            cursor.matchExistenceGuard()
            dropObjects(&cursor)
        case "INDEX":
            cursor.advance()
            _ = cursor.match("CONCURRENTLY")
            cursor.matchExistenceGuard()
            for piece in cursor.splitTopLevel(cursor.remaining) {
                var pieceCursor = SQLCursor(cursor.stream, range: piece)
                guard let name = readObjectName(&pieceCursor) else { continue }
                indexes.removeValue(forKey: objectKey(name))
            }
        case "TRIGGER":
            cursor.advance()
            cursor.matchExistenceGuard()
            guard let name = readObjectName(&cursor), cursor.match("ON"),
                  let tableName = readObjectName(&cursor) else { return }
            triggers.removeValue(forKey: "\(objectKey(tableName))|\(name.name.lowercased())")
        default:
            break
        }
    }

    private func dropObjects(_ cursor: inout SQLCursor) {
        for piece in cursor.splitTopLevel(cursor.remaining) {
            var pieceCursor = SQLCursor(cursor.stream, range: piece)
            guard let name = readObjectName(&pieceCursor) else { continue }
            let key = objectKey(name)
            guard tables.removeValue(forKey: key) != nil else { continue }
            indexes = indexes.filter { $0.value.tableKey != key }
            triggers = triggers.filter { $0.value.tableKey != key }
            partitionChildCounts.removeValue(forKey: key)
            for (otherKey, var other) in tables {
                let before = other.foreignKeys.count
                other.foreignKeys.removeAll { $0.targetKey == key }
                if other.foreignKeys.count != before { tables[otherKey] = other }
            }
        }
    }

    // MARK: - COMMENT ON

    private func applyComment(_ cursor: inout SQLCursor) {
        cursor.advance()
        guard cursor.match("ON") else { return }
        let isColumn: Bool
        switch cursor.peekKeyword() {
        case "TABLE", "VIEW":
            cursor.advance()
            isColumn = false
        case "MATERIALIZED":
            cursor.advance()
            _ = cursor.match("VIEW")
            isColumn = false
        case "COLUMN":
            cursor.advance()
            isColumn = true
        default:
            return
        }

        let parts = cursor.readIdentifierParts()
        guard !parts.isEmpty, cursor.match("IS") else { return }
        let value = cursor.peek().flatMap { $0.kind == .string ? $0.text : nil }
        let folded = parts.map { dialect.fold($0.text, quoted: $0.quoted) }

        if isColumn {
            guard folded.count >= 2 else { return }
            let columnName = folded[folded.count - 1]
            let tableParts = Array(folded.dropLast())
            let key = objectKey(qualify(tableParts))
            guard var table = tables[key], let index = table.columnIndex(named: columnName) else { return }
            table.columns[index].comment = value
            tables[key] = table
        } else {
            let key = objectKey(qualify(folded))
            guard var table = tables[key] else { return }
            table.comment = value
            tables[key] = table
        }
    }

    // MARK: - Naming

    private typealias ObjectName = (schema: String?, name: String)

    private func qualify(_ folded: [String]) -> ObjectName {
        switch dialect {
        case .postgreSQL:
            if folded.count >= 2 { return (folded[folded.count - 2], folded[folded.count - 1]) }
            return (searchPathSchema ?? "public", folded[0])
        case .sqlite:
            return (nil, folded[folded.count - 1])
        }
    }

    private func readObjectName(_ cursor: inout SQLCursor) -> ObjectName? {
        let parts = cursor.readIdentifierParts()
        guard !parts.isEmpty else { return nil }
        return qualify(parts.map { dialect.fold($0.text, quoted: $0.quoted) })
    }

    private func readIdentifier(_ cursor: inout SQLCursor) -> String? {
        guard let token = cursor.peek(), token.isIdentifier else { return nil }
        cursor.advance()
        return dialect.fold(token.text, quoted: token.kind == .quotedIdentifier)
    }

    private func objectKey(_ name: ObjectName) -> String {
        guard let schema = name.schema, !schema.isEmpty else { return name.name.lowercased() }
        return "\(schema).\(name.name)".lowercased()
    }

    // MARK: - Column lists

    /// Plain column names from a key or index element list. Expression elements
    /// are dropped unless `allowsExpressions` keeps their source text.
    private func keyColumns(in range: Range<Int>, cursor: SQLCursor, allowsExpressions: Bool = false) -> [String] {
        cursor.splitTopLevel(range).compactMap { piece -> String? in
            let pieceCursor = SQLCursor(cursor.stream, range: piece)
            guard let first = pieceCursor.peek(), first.isIdentifier,
                  !(pieceCursor.peek(1).map { $0.kind == .symbol && ($0.text == "(" || $0.text == ".") } ?? false)
            else {
                return allowsExpressions ? cursor.source(piece) : nil
            }
            return dialect.fold(first.text, quoted: first.kind == .quotedIdentifier)
        }
    }

    /// Best-effort list of this table's columns mentioned in an expression,
    /// used to attach CHECK constraints to the columns they constrain.
    private func referencedColumns(in range: Range<Int>, cursor: SQLCursor, table: MigrationTable) -> [String] {
        var seen: [String] = []
        for index in range {
            guard let token = cursor.stream.tokens[safe: index], token.isIdentifier else { continue }
            let name = dialect.fold(token.text, quoted: token.kind == .quotedIdentifier)
            guard table.columnIndex(named: name) != nil, !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen
    }

    // MARK: - Diagnostics

    private func note(_ message: String, _ cursor: SQLCursor) {
        guard diagnostics.count < Self.diagnosticLimit else { return }
        let preview = String(cursor.stream.source(0..<cursor.stream.tokens.count).prefix(140))
            .replacingOccurrences(of: "\n", with: " ")
        let diagnostic = MigrationDiagnostic(fileName: fileName, message: message, statementPreview: preview)
        guard diagnosticIdentifiers.insert(diagnostic.id).inserted else { return }
        diagnostics.append(diagnostic)
    }

    // MARK: - Snapshot

    func makeModel(fileCount: Int) -> MigrationSchemaModel {
        let snapshot = MigrationCatalogAssembler(
            dialect: dialect,
            tables: tables,
            indexes: indexes,
            triggers: triggers,
            partitionChildCounts: partitionChildCounts
        ).assemble()
        return MigrationSchemaModel(
            catalog: snapshot.catalog,
            diagnostics: diagnostics,
            fileCount: fileCount,
            statementCount: statementCount,
            dialect: dialect
        )
    }
}
