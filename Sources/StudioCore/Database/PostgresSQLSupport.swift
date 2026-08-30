import Foundation

public enum PostgresQueryParameter: Sendable, Hashable {
    case null
    case text(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
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

public enum PostgresTableQueryBuilder {
    public static func makePlan(
        query: TableQueryState,
        descriptor: TableDescriptor
    ) throws -> PostgresTableQueryPlan {
        let knownColumns = Set(descriptor.columns.map(\.name))
        var conditions: [String] = []
        var parameters: [PostgresQueryParameter] = []

        let searchText = query.sanitizedSearchText
        let searchColumns = descriptor.columns.filter { column in
            column.affinity == .text || column.affinity == .none
        }
        if !searchText.isEmpty, !searchColumns.isEmpty {
            let pattern = "%\(searchText)%"
            let searchConditions = searchColumns.map { column in
                parameters.append(.text(pattern))
                return "CAST(\(quoteIdentifier(column.name)) AS TEXT) ILIKE $\(parameters.count)"
            }
            conditions.append("(\(searchConditions.joined(separator: " OR ")))" )
        }

        for filter in query.sanitizedFilters {
            guard knownColumns.contains(filter.columnName) else {
                throw DatabaseUserError(kind: .invalidInput, message: "Unknown column \(filter.columnName).")
            }
            parameters.append(.text("%\(filter.value)%"))
            conditions.append("CAST(\(quoteIdentifier(filter.columnName)) AS TEXT) ILIKE $\(parameters.count)")
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        var orderTerms: [String] = []

        if let sort = query.sort {
            guard knownColumns.contains(sort.columnName) else {
                throw DatabaseUserError(kind: .invalidInput, message: "Unknown sort column \(sort.columnName).")
            }
            orderTerms.append("\(quoteIdentifier(sort.columnName)) \(sort.direction.sqlKeyword) NULLS LAST")
        }

        for fallback in descriptor.fallbackSortColumns where knownColumns.contains(fallback) {
            guard !orderTerms.contains(where: { $0.hasPrefix(quoteIdentifier(fallback) + " ") }) else { continue }
            orderTerms.append("\(quoteIdentifier(fallback)) ASC NULLS LAST")
        }
        if orderTerms.isEmpty, let firstColumn = descriptor.columns.first {
            orderTerms.append("\(quoteIdentifier(firstColumn.name)) ASC NULLS LAST")
        }

        parameters.append(.integer(Int64(max(0, query.limit))))
        let limitParameter = parameters.count
        parameters.append(.integer(Int64(max(0, query.offset))))
        let offsetParameter = parameters.count

        let orderClause = orderTerms.isEmpty ? "" : " ORDER BY " + orderTerms.joined(separator: ", ")
        let selectedColumns = descriptor.columns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
        let table = descriptor.qualifiedSQLIdentifier
        let countParameterCount = parameters.count - 2

        let countSQL = "SELECT COUNT(*) FROM \(table)\(whereClause)"
        let selectSQL = "SELECT \(selectedColumns) FROM \(table)\(whereClause)\(orderClause) LIMIT $\(limitParameter) OFFSET $\(offsetParameter)"

        return PostgresTableQueryPlan(
            countSQL: countSQL,
            selectSQL: selectSQL,
            parameters: parameters,
            countParameterCount: countParameterCount
        )
    }
}

/// A conservative lexical gate for the user query editor. It deliberately
/// rejects suspicious words anywhere outside literals/comments: PostgreSQL's
/// server-side read-only transaction remains the final authority.
public enum ReadOnlySQLPolicy {
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
