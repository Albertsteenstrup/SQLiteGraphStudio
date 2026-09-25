import Foundation

/// A conservative lexical gate for SQL sent through the MCP automation API.
/// The app must still execute accepted SQL on its read-only database connection.
public enum MCPReadOnlySQLPolicy {
    public static let maximumSQLCharacters = 100_000

    private static let allowedRoots: Set<String> = ["SELECT", "VALUES", "WITH"]

    private static let forbiddenWords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME",
        "ATTACH", "DETACH", "PRAGMA", "EXPLAIN", "VACUUM", "REINDEX", "ANALYZE",
        "BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE", "TRANSACTION",
        "INTO", "LOAD_EXTENSION", "WRITEFILE", "WRITE_FILE", "READFILE", "READ_FILE",
        "NEXTVAL", "SETVAL", "SET_CONFIG", "PG_NOTIFY", "PG_ADVISORY_LOCK", "PG_ADVISORY_XACT_LOCK",
        "PG_ADVISORY_LOCK_SHARED", "PG_ADVISORY_XACT_LOCK_SHARED", "PG_TRY_ADVISORY_LOCK",
        "PG_TRY_ADVISORY_XACT_LOCK", "PG_TRY_ADVISORY_LOCK_SHARED", "PG_TRY_ADVISORY_XACT_LOCK_SHARED",
        "PG_ADVISORY_UNLOCK", "PG_ADVISORY_UNLOCK_ALL", "PG_ADVISORY_UNLOCK_SHARED", "PG_CANCEL_BACKEND",
        "PG_TERMINATE_BACKEND", "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_WRITE_FILE", "PG_LS_DIR",
        "PG_STAT_FILE", "PG_SLEEP", "DBLINK", "DBLINK_EXEC", "LO_CREAT", "LO_CREATE", "LO_UNLINK",
        "LO_OPEN", "LO_TRUNCATE", "LO_TRUNCATE64", "LO_IMPORT", "LO_EXPORT", "LO_PUT", "LOWRITE",
    ]

    /// Functions accepted here are common pure SQL value, aggregate, window,
    /// JSON, math and date/time functions from SQLite and PostgreSQL, plus
    /// SQLite FTS5 scoring helpers. Unknown calls are rejected so a registered
    /// extension or UDF cannot silently widen the MCP query surface.
    private static let allowedFunctions: Set<String> = [
        "ABS", "AGE", "ARRAY_AGG", "ARRAY_APPEND", "ARRAY_LENGTH", "ARRAY_TO_STRING", "ARRAY_TO_JSON",
        "ASCII", "AVG", "BOOL_AND", "BOOL_OR", "BTRIM", "CARDINALITY", "CAST", "CEIL", "CEILING",
        "CHAR", "CHANGES", "CHR", "CLOCK_TIMESTAMP", "COALESCE", "CONCAT", "CONCAT_WS", "COUNT",
        "DATE", "DATE_PART", "DATE_TRUNC", "DATETIME", "DENSE_RANK", "DECODE", "DEGREES", "ENCODE",
        "EXP", "EXTRACT", "FACTORIAL", "FIRST_VALUE", "FORMAT", "GREATEST", "GENERATE_SERIES", "GLOB", "GROUPING", "LEAST",
        "GROUP_CONCAT", "HEX", "INITCAP", "JSON_AGG", "JSON_ARRAYAGG", "JSON_BUILD_ARRAY", "JSON_BUILD_OBJECT",
        "JSON_EACH", "JSON_EACH_TEXT", "JSON_OBJECT_AGG", "JSON_OBJECT_KEYS", "JSON_POPULATE_RECORD",
        "JSON_STRIP_NULLS", "JSON_TO_RECORD", "JSON_TO_RECORDSET", "JSON_TYPEOF", "JSONB_AGG",
        "JSONB_ARRAYAGG", "JSONB_BUILD_ARRAY", "JSONB_BUILD_OBJECT", "JSONB_EACH", "JSONB_EACH_TEXT",
        "JSONB_OBJECT_AGG", "JSONB_OBJECT_KEYS", "JSONB_PATH_EXISTS", "JSONB_PATH_QUERY", "JSONB_POPULATE_RECORD",
        "JSONB_STRIP_NULLS", "JSONB_TO_RECORD", "JSONB_TO_RECORDSET", "JSONB_TYPEOF", "LEFT", "LN",
        "MAKE_DATE", "MAKE_INTERVAL", "MAKE_TIME", "MAKE_TIMESTAMP", "MAKE_TIMESTAMPTZ", "MD5", "NOW",
        "PG_TYPEOF", "POSITION", "REGEXP_MATCH", "REGEXP_MATCHES", "REGEXP_REPLACE", "REGEXP_SPLIT_TO_ARRAY",
        "REGEXP_SPLIT_TO_TABLE", "REVERSE", "RIGHT", "ROW_TO_JSON", "SHA224", "SHA256", "SPLIT_PART",
        "STATEMENT_TIMESTAMP", "STRING_AGG", "TO_CHAR", "TO_DATE", "TO_HEX", "TO_JSON", "TO_JSONB",
        "TO_NUMBER", "TO_TIMESTAMP", "TRANSACTION_TIMESTAMP", "TRANSLATE", "TRIM_SCALE", "WIDTH_BUCKET",
        "XMLATTRIBUTES", "XMLCOMMENT", "XMLCONCAT", "XMLELEMENT", "XMLFOREST", "XMLPI", "XMLROOT",
        "XMLSERIALIZE",
        "IFNULL", "IIF", "INSTR", "JSON", "JSON_ARRAY", "JSON_ARRAY_LENGTH", "JSON_ERROR_POSITION",
        "JSON_EXTRACT", "JSON_INSERT", "JSON_OBJECT", "JSON_PATCH", "JSON_REMOVE", "JSON_REPLACE",
        "JSON_SET", "JSON_TYPE", "JSON_VALID", "JSON_QUOTE", "JSONB", "JSONB_ARRAY", "JSONB_OBJECT",
        "JSONB_ARRAY_LENGTH", "JSONB_EXTRACT", "JSONB_INSERT", "JSONB_PATCH", "JSONB_REMOVE",
        "JSONB_REPLACE", "JSONB_SET", "JULIANDAY", "LAG", "LAST_INSERT_ROWID", "LAST_VALUE", "LEAD",
        "LENGTH", "LIKELIHOOD", "LIKELY", "LN", "LOG", "LOG10", "LOG2", "LOWER",
        "LTRIM", "MAX", "MIN", "MOD", "NTH_VALUE", "NTILE", "NULLIF", "OCTET_LENGTH", "PI",
        "PERCENT_RANK", "POW", "POWER", "PRINTF", "QUOTE", "RADIANS", "RANDOM",
        "RANK", "REPLACE", "ROUND", "ROW_NUMBER", "RTRIM", "SIGN", "SIN", "SINH", "SOUNDEX",
        "SQRT", "SQLITE_COMPILEOPTION_GET", "SQLITE_COMPILEOPTION_USED", "SQLITE_OFFSET",
        "SQLITE_SOURCE_ID", "SQLITE_VERSION", "STRFTIME", "STRING_AGG", "SUBSTR", "SUBSTRING", "SUM",
        "TAN", "TANH", "TIME", "TIMEDIFF", "TOTAL", "TOTAL_CHANGES", "TRIM", "TRUNC", "TYPEOF",
        "UNHEX", "UNICODE", "UNIXEPOCH", "UNLIKELY", "UPPER",
        "ACOS", "ACOSH", "ASIN", "ASINH", "ATAN", "ATAN2", "ATANH", "CEIL", "CEILING", "COS",
        "COSH", "DEGREES", "EXP", "FLOOR", "FORMAT", "LOG", "LOG10", "LOG2", "MOD", "POW", "POWER",
        "RADIANS", "SIN", "SINH", "SQRT", "TAN", "TANH", "TRUNC",
        "BM25", "HIGHLIGHT", "OFFSETS", "SNIPPET",
        "JSON_TREE",
    ]

    private static let syntaxWordsBeforeParenthesis: Set<String> = [
        "ALL", "ANY", "AS", "CASE", "CAST", "EXISTS", "FILTER", "FROM", "IN", "NOT", "OVER", "ROW", "SELECT", "VALUES",
        "WHERE", "WITH",
    ]

    /// Validates one read-only SQL statement. It deliberately rejects PRAGMA
    /// and EXPLAIN; callers should use the app's dedicated schema and explain
    /// tools instead.
    public static func validate(_ sql: String) throws {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPReadOnlySQLPolicyError.emptyQuery
        }
        guard sql.count <= maximumSQLCharacters else {
            throw MCPReadOnlySQLPolicyError.rejected("SQL exceeds the MCP limit of \(maximumSQLCharacters) characters.")
        }

        var scanner = MCPReadOnlySQLScanner(sql)
        let tokens = try scanner.scan()
        let semicolonIndexes = tokens.indices.filter { tokens[$0] == .symbol(";") }
        if semicolonIndexes.count > 1 || (semicolonIndexes.first.map { $0 != tokens.count - 1 } ?? false) {
            throw MCPReadOnlySQLPolicyError.rejected("Only one SQL statement is allowed per MCP request.")
        }

        let statementEnd = semicolonIndexes.first ?? tokens.endIndex
        let statementTokens = Array(tokens[..<statementEnd])
        guard let first = statementTokens.first, case .word(let root) = first, allowedRoots.contains(root) else {
            throw MCPReadOnlySQLPolicyError.rejected("MCP query mode only allows SELECT, VALUES, or read-only WITH statements.")
        }

        for index in statementTokens.indices {
            guard case .word(let word) = statementTokens[index] else { continue }
            if forbiddenWords.contains(word) {
                throw MCPReadOnlySQLPolicyError.rejected("The MCP read-only query policy rejects \(word) statements or operations.")
            }
            if word == "REPLACE",
               !(statementTokens.indices.contains(index + 1) && statementTokens[index + 1] == .symbol("(")) {
                throw MCPReadOnlySQLPolicyError.rejected("The MCP read-only query policy rejects REPLACE statements.")
            }
        }

        let cteDeclarationIndexes = cteDeclarationNameIndexes(in: statementTokens)
        for index in statementTokens.indices where index + 1 < statementTokens.count {
            guard let name = identifierName(statementTokens[index]),
                  statementTokens[index + 1] == .symbol("("),
                  !cteDeclarationIndexes.contains(index),
                  !syntaxWordsBeforeParenthesis.contains(name)
            else { continue }

            guard allowedFunctions.contains(name), !name.hasPrefix("PRAGMA_") else {
                throw MCPReadOnlySQLPolicyError.rejected("The MCP read-only query policy does not allow function \(name)().")
            }
            if index >= 2, statementTokens[index - 1] == .symbol("."),
               identifierName(statementTokens[index - 2]) != nil {
                throw MCPReadOnlySQLPolicyError.rejected("The MCP read-only query policy does not allow schema-qualified function calls.")
            }
        }
    }

    private static func identifierName(_ token: MCPReadOnlySQLToken) -> String? {
        switch token {
        case .word(let value), .quotedIdentifier(let value): value
        case .symbol, .literal: nil
        }
    }

    /// Finds names at the beginning of CTE declarations so `WITH rows(col) AS`
    /// is not mistaken for a function call. Expressions inside each CTE remain
    /// fully scanned and checked.
    private static func cteDeclarationNameIndexes(in tokens: [MCPReadOnlySQLToken]) -> Set<Int> {
        guard tokens.first == .word("WITH") else { return [] }
        var index = 1
        if tokens.indices.contains(index), tokens[index] == .word("RECURSIVE") { index += 1 }
        var names = Set<Int>()

        while tokens.indices.contains(index), identifierName(tokens[index]) != nil {
            names.insert(index)
            index += 1

            if tokens.indices.contains(index), tokens[index] == .symbol("(") {
                guard let close = matchingClose(in: tokens, openAt: index) else { return names }
                index = close + 1
            }

            guard tokens.indices.contains(index), tokens[index] == .word("AS") else { return names }
            index += 1
            if tokens.indices.contains(index), tokens[index] == .word("NOT") {
                index += 1
                if tokens.indices.contains(index), tokens[index] == .word("MATERIALIZED") { index += 1 }
            } else if tokens.indices.contains(index), tokens[index] == .word("MATERIALIZED") {
                index += 1
            }

            guard tokens.indices.contains(index), tokens[index] == .symbol("("),
                  let close = matchingClose(in: tokens, openAt: index)
            else { return names }
            index = close + 1
            guard tokens.indices.contains(index), tokens[index] == .symbol(",") else { return names }
            index += 1
        }
        return names
    }

    private static func matchingClose(in tokens: [MCPReadOnlySQLToken], openAt start: Int) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            switch tokens[index] {
            case .symbol("("): depth += 1
            case .symbol(")"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}

public enum MCPReadOnlySQLPolicyError: Error, Equatable, LocalizedError {
    case emptyQuery
    case malformed(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "Enter a SQL query first."
        case .malformed(let message), .rejected(let message): message
        }
    }
}

private enum MCPReadOnlySQLToken: Equatable {
    case word(String)
    case quotedIdentifier(String)
    case symbol(Unicode.Scalar)
    case literal
}

/// The same SQL text is sent to SQLite or PostgreSQL, so every lexical region
/// the scanner skips must end at the same place in both dialects. Where they
/// disagree (nested comments, dollar quoting, backslash escapes, `[`), the
/// scanner rejects the form rather than guess which engine will run it. It
/// walks Unicode scalars, not grapheme clusters, because both engines see a
/// quote followed by a combining mark as a quote.
private struct MCPReadOnlySQLScanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ sql: String) {
        scalars = Array(sql.unicodeScalars)
    }

    mutating func scan() throws -> [MCPReadOnlySQLToken] {
        var tokens: [MCPReadOnlySQLToken] = []
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace {
                index += 1
            } else if scalar == "-", peek(1) == "-" {
                try skipLineComment()
            } else if scalar == "/", peek(1) == "*" {
                try skipBlockComment()
            } else if scalar == "'" {
                let containsBackslash = try skipStringLiteral()
                if containsBackslash, tokens.last == .word("E") {
                    throw MCPReadOnlySQLPolicyError.rejected(
                        "E'...' strings with backslash escapes are not allowed in MCP queries; use a standard string."
                    )
                }
                tokens.append(.literal)
            } else if scalar == "\"" {
                tokens.append(.quotedIdentifier(try readQuotedIdentifier()))
            } else if scalar == "`" || scalar == "[" {
                tokens.append(.quotedIdentifier(try readPlainQuotedIdentifier(opening: scalar)))
            } else if scalar == "$" {
                throw MCPReadOnlySQLPolicyError.rejected(
                    "Dollar-quoted strings and $ parameters are not allowed in MCP queries."
                )
            } else if isIdentifierStart(scalar) {
                tokens.append(.word(readWord()))
            } else {
                tokens.append(.symbol(scalar))
                index += 1
            }
        }
        return tokens
    }

    private func peek(_ distance: Int) -> Unicode.Scalar? {
        let target = index + distance
        return scalars.indices.contains(target) ? scalars[target] : nil
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic
    }

    private func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private mutating func readWord() -> String {
        let start = index
        while index < scalars.count, isNameCharacter(scalars[index]) || scalars[index] == "$" {
            index += 1
        }
        return String(String.UnicodeScalarView(scalars[start..<index])).uppercased()
    }

    /// PostgreSQL ends a line comment at CR or LF and SQLite only at LF, so a
    /// lone CR would leave the rest of that line as code in one dialect only.
    private mutating func skipLineComment() throws {
        index += 2
        while index < scalars.count, scalars[index] != "\n" {
            if scalars[index] == "\r" {
                guard peek(1) == "\n" else {
                    throw MCPReadOnlySQLPolicyError.rejected("Line comments may not contain a bare carriage return.")
                }
                return
            }
            index += 1
        }
    }

    /// PostgreSQL nests block comments and SQLite does not, so any inner `/*`
    /// would make the two disagree about where the comment ends.
    private mutating func skipBlockComment() throws {
        index += 2
        while index < scalars.count {
            if scalars[index] == "*", peek(1) == "/" {
                index += 2
                return
            }
            if scalars[index] == "/", peek(1) == "*" {
                throw MCPReadOnlySQLPolicyError.rejected("Nested block comments are not allowed in MCP queries.")
            }
            index += 1
        }
        throw MCPReadOnlySQLPolicyError.malformed("The query contains an unterminated comment.")
    }

    /// Returns whether the literal contained a backslash, which only changes
    /// its extent for PostgreSQL E'...' strings.
    private mutating func skipStringLiteral() throws -> Bool {
        index += 1
        var containsBackslash = false
        while index < scalars.count {
            if scalars[index] == "'" {
                if peek(1) == "'" {
                    index += 2
                } else {
                    index += 1
                    return containsBackslash
                }
            } else {
                if scalars[index] == "\\" { containsBackslash = true }
                index += 1
            }
        }
        throw MCPReadOnlySQLPolicyError.malformed("The query contains an unterminated string literal.")
    }

    private mutating func readQuotedIdentifier() throws -> String {
        index += 1
        var value = String.UnicodeScalarView()
        while index < scalars.count {
            if scalars[index] == "\"" {
                if peek(1) == "\"" {
                    value.append("\"")
                    index += 2
                } else {
                    index += 1
                    return String(value).uppercased()
                }
            } else {
                value.append(scalars[index])
                index += 1
            }
        }
        throw MCPReadOnlySQLPolicyError.malformed("The query contains an unterminated quoted identifier.")
    }

    /// SQLite reads `[...]` and backticks as quoted identifiers; PostgreSQL
    /// reads `[` as an array subscript or ARRAY constructor and the contents as
    /// code. Content limited to names, numbers and simple separators means the
    /// same thing in both and cannot hide a call, string or comment.
    private mutating func readPlainQuotedIdentifier(opening: Unicode.Scalar) throws -> String {
        let closing: Unicode.Scalar = opening == "[" ? "]" : opening
        index += 1
        var value = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == closing {
                index += 1
                return String(value).uppercased()
            }
            guard isNameCharacter(scalar) || scalar == " " || scalar == "," || scalar == "." || scalar == ":" else {
                throw MCPReadOnlySQLPolicyError.rejected(
                    "\(opening)...\(closing) may only contain letters, digits, underscores, spaces, commas, periods, or colons in MCP queries; use double-quoted identifiers instead."
                )
            }
            value.append(scalar)
            index += 1
        }
        throw MCPReadOnlySQLPolicyError.malformed("The query contains an unterminated quoted identifier.")
    }
}
