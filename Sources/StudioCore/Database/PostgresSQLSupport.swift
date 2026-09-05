import Foundation

public enum PostgresQueryParameter: Sendable, Hashable {
    case null
    case text(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case bytes(Data)
}

public struct PostgresTableQueryPlan: Sendable, Hashable {
    public let countSQL: String
    public let selectSQL: String
    public let parameters: [PostgresQueryParameter]
    public let countParameterCount: Int

    public init(
        countSQL: String,
        selectSQL: String,
        parameters: [PostgresQueryParameter],
        countParameterCount: Int
    ) {
        self.countSQL = countSQL
        self.selectSQL = selectSQL
        self.parameters = parameters
        self.countParameterCount = countParameterCount
    }

    public var countParameters: ArraySlice<PostgresQueryParameter> {
        parameters.prefix(countParameterCount)
    }
}

public enum TableSQLDialect: Sendable { case sqlite, postgres }

public enum PostgresTableQueryBuilder {
    public static func order(query: TableQueryState, descriptor: TableDescriptor) throws -> [SortState] {
        let known = Set(descriptor.columns.map(\.name))
        var order: [SortState] = []
        if let sort = query.sort {
            guard known.contains(sort.columnName) else { throw invalid("Unknown sort column \(sort.columnName).") }
            order.append(sort)
        }
        let fallback = descriptor.paginationKeyColumns.isEmpty
            ? descriptor.fallbackSortColumns.filter { name in descriptor.columns.first(where: { $0.name == name })?.declaredType.lowercased() != "json" }
            : descriptor.paginationKeyColumns
        for name in fallback where !order.contains(where: { $0.columnName == name }) {
            order.append(.init(columnName: name, direction: .ascending))
        }
        return order
    }

    public static func makePlan(query: TableQueryState, descriptor: TableDescriptor, dialect: TableSQLDialect = .postgres) throws -> PostgresTableQueryPlan {
        guard query.offset >= 0, query.limit >= 0 else { throw invalid("Page offset and limit must not be negative.") }
        let columns = Dictionary(uniqueKeysWithValues: descriptor.columns.map { ($0.name, $0) })
        var parameters: [PostgresQueryParameter] = []
        var conditions: [String] = []
        func bind(_ value: PostgresQueryParameter) -> String {
            parameters.append(value)
            return dialect == .postgres ? "$\(parameters.count)" : "?"
        }
        func literalPattern(_ value: String) -> String {
            "%" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        }
        func contains(_ name: String, _ value: String) -> String {
            "CAST(\(quoteIdentifier(name)) AS TEXT) \(dialect == .postgres ? "ILIKE" : "LIKE") \(bind(.text(literalPattern(value)))) ESCAPE '\\'"
        }
        func operand(_ text: String, column: TableColumn) throws -> String {
            let type = column.declaredType.lowercased()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "boolean" || type == "bool" {
                guard ["true", "false", "1", "0"].contains(trimmed.lowercased()) else { throw invalid("\(column.name) requires true or false.") }
                return bind(.boolean(trimmed == "1" || trimmed.lowercased() == "true"))
            }
            if column.affinity == .integer {
                guard let value = Int64(trimmed) else { throw invalid("\(column.name) requires a whole number in the 64-bit range.") }
                return bind(.integer(value))
            }
            if column.affinity == .real {
                guard let value = Double(trimmed), value.isFinite else { throw invalid("\(column.name) requires a finite number.") }
                return bind(.double(value))
            }
            if type.hasPrefix("numeric") || type.hasPrefix("decimal") {
                guard trimmed.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw invalid("\(column.name) requires a decimal number.") }
                return "CAST(\(bind(.text(trimmed))) AS NUMERIC)"
            }
            let parameter = bind(.text(text))
            guard dialect == .postgres else { return parameter }
            let casts = ["uuid", "date", "time", "time without time zone", "time with time zone", "timestamp", "timestamp without time zone", "timestamp with time zone", "timestamptz", "timetz", "jsonb"]
            return casts.contains(type) ? "CAST(\(parameter) AS \(type))" : parameter
        }
        if !query.sanitizedSearchText.isEmpty {
            let searchable = dialect == .postgres ? descriptor.columns.filter { $0.affinity == .text || $0.affinity == .none } : descriptor.searchableColumns
            if !searchable.isEmpty { conditions.append("(" + searchable.map { contains($0.name, query.sanitizedSearchText) }.joined(separator: " OR ") + ")") }
        }
        for filter in query.sanitizedFilters {
            guard let column = columns[filter.columnName] else { throw invalid("Unknown column \(filter.columnName).") }
            let name = quoteIdentifier(column.name)
            switch filter.comparison {
            case .contains: conditions.append(contains(column.name, filter.value))
            case .isNull: conditions.append("\(name) IS NULL")
            case .isNotNull: conditions.append("\(name) IS NOT NULL")
            case .between:
                guard let upper = filter.upperValue else { throw invalid("A range needs both lower and upper values.") }
                conditions.append("\(name) BETWEEN \(try operand(filter.value, column: column)) AND \(try operand(upper, column: column))")
            default:
                let operators: [ColumnFilterComparison: String] = [.equal: "=", .notEqual: "<>", .lessThan: "<", .lessThanOrEqual: "<=", .greaterThan: ">", .greaterThanOrEqual: ">="]
                conditions.append("\(name) \(operators[filter.comparison]!) \(try operand(filter.value, column: column))")
            }
        }
        let table = descriptor.qualifiedSQLIdentifier
        let countWhere = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let countParameterCount = parameters.count
        let order = try order(query: query, descriptor: descriptor)
        if let cursor = query.after {
            guard !descriptor.paginationKeyColumns.isEmpty else { throw invalid("This table has no reliable key for cursor paging.") }
            var alternatives: [String] = []
            for index in order.indices {
                var terms: [String] = []
                for previous in order[..<index] {
                    guard let value = cursor.values[previous.columnName] else { throw invalid("Incomplete page cursor.") }
                    let name = quoteIdentifier(previous.columnName)
                    if value == .null { terms.append("\(name) IS NULL") }
                    else { terms.append("\(name) = \(try cursorOperand(value, name: previous.columnName))") }
                }
                let sort = order[index]
                guard let value = cursor.values[sort.columnName] else { throw invalid("Incomplete page cursor.") }
                guard value != .null else { continue } // NULLS LAST; only later tie-breakers can advance.
                let name = quoteIdentifier(sort.columnName)
                let comparison = sort.direction == .ascending ? ">" : "<"
                terms.append("(\(name) \(comparison) \(try cursorOperand(value, name: sort.columnName)) OR \(name) IS NULL)")
                alternatives.append("(" + terms.joined(separator: " AND ") + ")")
            }
            conditions.append(alternatives.isEmpty ? "FALSE" : "(" + alternatives.joined(separator: " OR ") + ")")
        }
        func cursorOperand(_ value: DatabaseResultValue, name: String) throws -> String {
            if name == "_rowid_", case .integer(let id) = value { return bind(.integer(id)) }
            guard let column = columns[name] else { throw invalid("Unknown cursor column.") }
            if case .blob(let data) = value { return bind(.bytes(data)) }
            return try operand(ResultSerialization.exactText(value), column: column)
        }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let orderClause = order.isEmpty ? "" : " ORDER BY " + order.map { "\(quoteIdentifier($0.columnName)) \($0.direction.sqlKeyword) NULLS LAST" }.joined(separator: ", ")
        var projection = descriptor.columns.map { quoteIdentifier($0.name) }
        if dialect == .sqlite && descriptor.rowIdentityStrategy == .rowID { projection.append("_rowid_ AS __sgs_rowid__") }
        let limit = bind(.integer(Int64(query.limit)))
        let offset = bind(.integer(Int64(query.after == nil ? query.offset : 0)))
        return PostgresTableQueryPlan(countSQL: "SELECT COUNT(*) FROM \(table)\(countWhere)", selectSQL: "SELECT \(projection.joined(separator: ", ")) FROM \(table)\(whereClause)\(orderClause) LIMIT \(limit) OFFSET \(offset)", parameters: parameters, countParameterCount: countParameterCount)
    }
    private static func invalid(_ message: String) -> DatabaseUserError { .init(kind: .invalidInput, message: message) }
}

/// A conservative lexical gate for the user query editor. It deliberately
/// rejects suspicious words anywhere outside literals/comments: PostgreSQL's
/// server-side read-only transaction remains the final authority.
public enum ReadOnlySQLPolicy {
    static func statementRoot(_ sql: String) throws -> String? {
        var scanner = SQLScanner(sql)
        return try scanner.scan().first
    }

    public static func validate(_ sql: String) throws -> Void? {
        var scanner = SQLScanner(sql)
        let tokens = try scanner.scan()
        guard !tokens.isEmpty else {
            throw DatabaseUserError(kind: .invalidInput, message: "Enter a SQL query first.")
        }

        let semicolonIndexes = tokens.indices.filter { tokens[$0] == ";" }
        if semicolonIndexes.count > 1 || (semicolonIndexes.first.map { $0 != tokens.count - 1 } ?? false) {
            throw rejection("Only one read-only statement may be executed at a time.")
        }

        let words = tokens.filter { $0 != ";" }
        guard let first = words.first else {
            throw DatabaseUserError(kind: .invalidInput, message: "Enter a SQL query first.")
        }

        let allowedRoots: Set<String> = ["SELECT", "VALUES", "SHOW", "WITH", "EXPLAIN"]
        guard allowedRoots.contains(first) else {
            throw rejection("Only SELECT, VALUES, SHOW, read-only CTE, or EXPLAIN statements are allowed.")
        }

        if first == "EXPLAIN", words.dropFirst().contains("ANALYZE") {
            throw rejection("EXPLAIN ANALYZE is not allowed because it can execute the query.")
        }

        let forbidden: Set<String> = [
            "INSERT", "UPDATE", "DELETE", "MERGE", "CREATE", "ALTER", "DROP", "TRUNCATE",
            "COPY", "CALL", "DO", "SET", "RESET", "BEGIN", "START", "COMMIT", "ROLLBACK",
            "SAVEPOINT", "RELEASE", "GRANT", "REVOKE", "VACUUM", "REINDEX", "CLUSTER",
            "COMMENT", "LOCK", "LISTEN", "NOTIFY", "DISCARD", "PREPARE", "EXECUTE",
            "DECLARE", "FETCH", "MOVE", "CLOSE", "CHECKPOINT", "REFRESH", "ANALYZE", "INTO",
            "NEXTVAL", "SETVAL", "PG_ADVISORY_LOCK", "PG_ADVISORY_XACT_LOCK", "PG_CANCEL_BACKEND",
            "PG_TERMINATE_BACKEND", "PG_ADVISORY_LOCK_SHARED", "PG_ADVISORY_XACT_LOCK_SHARED",
            "PG_TRY_ADVISORY_LOCK", "PG_TRY_ADVISORY_XACT_LOCK", "PG_TRY_ADVISORY_LOCK_SHARED",
            "PG_TRY_ADVISORY_XACT_LOCK_SHARED", "PG_ADVISORY_UNLOCK", "PG_ADVISORY_UNLOCK_ALL",
            "PG_NOTIFY", "SET_CONFIG", "LO_CREAT", "LO_UNLINK", "LO_OPEN", "LO_TRUNCATE"
        ]
        if let word = words.first(where: { forbidden.contains($0) }) {
            throw rejection("The read-only query policy rejects \(word) statements or functions.")
        }

        return nil
    }

    private static func rejection(_ message: String) -> DatabaseUserError {
        DatabaseUserError(kind: .readOnly, message: message)
    }
}

private struct SQLScanner {
    private let characters: [Character]
    private var index: Int = 0

    init(_ sql: String) {
        characters = Array(sql)
    }

    mutating func scan() throws -> [String] {
        var tokens: [String] = []
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "-", peek(1) == "-" {
                skipLineComment()
                continue
            }
            if character == "/", peek(1) == "*" {
                try skipBlockComment()
                continue
            }
            if character == "'" {
                try skipSingleQuotedLiteral()
                continue
            }
            if character == "\"" {
                try skipQuotedIdentifier()
                continue
            }
            if character == "$", let delimiter = dollarQuoteDelimiter() {
                try skipDollarQuotedLiteral(delimiter)
                continue
            }
            if character == ";" {
                tokens.append(";")
                index += 1
                continue
            }
            if character.isLetter || character == "_" {
                var word = ""
                while index < characters.count {
                    let next = characters[index]
                    guard next.isLetter || next.isNumber || next == "_" || next == "$" else { break }
                    word.append(next)
                    index += 1
                }
                tokens.append(word.uppercased())
                continue
            }
            index += 1
        }
        return tokens
    }

    private func peek(_ distance: Int) -> Character? {
        let position = index + distance
        return characters.indices.contains(position) ? characters[position] : nil
    }

    private mutating func skipLineComment() {
        index += 2
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
    }

    private mutating func skipBlockComment() throws {
        index += 2
        var depth = 1
        while index < characters.count {
            if characters[index] == "/", peek(1) == "*" {
                depth += 1
                index += 2
            } else if characters[index] == "*", peek(1) == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                index += 1
            }
        }
        throw DatabaseUserError(kind: .syntax, message: "The query contains an unterminated comment.")
    }

    private mutating func skipSingleQuotedLiteral() throws {
        index += 1
        while index < characters.count {
            if characters[index] == "'" {
                if peek(1) == "'" {
                    index += 2
                } else {
                    index += 1
                    return
                }
            } else {
                index += 1
            }
        }
        throw DatabaseUserError(kind: .syntax, message: "The query contains an unterminated string literal.")
    }

    private mutating func skipQuotedIdentifier() throws {
        index += 1
        while index < characters.count {
            if characters[index] == "\"" {
                if peek(1) == "\"" {
                    index += 2
                } else {
                    index += 1
                    return
                }
            } else {
                index += 1
            }
        }
        throw DatabaseUserError(kind: .syntax, message: "The query contains an unterminated quoted identifier.")
    }

    private func dollarQuoteDelimiter() -> String? {
        guard characters[index] == "$" else { return nil }
        var position = index + 1
        while position < characters.count, characters[position].isLetter || characters[position].isNumber || characters[position] == "_" {
            position += 1
        }
        guard position < characters.count, characters[position] == "$" else { return nil }
        return String(characters[index...position])
    }

    private mutating func skipDollarQuotedLiteral(_ delimiter: String) throws {
        index += delimiter.count
        while index + delimiter.count <= characters.count {
            let candidate = String(characters[index..<(index + delimiter.count)])
            if candidate == delimiter {
                index += delimiter.count
                return
            }
            index += 1
        }
        throw DatabaseUserError(kind: .syntax, message: "The query contains an unterminated dollar-quoted literal.")
    }
}
