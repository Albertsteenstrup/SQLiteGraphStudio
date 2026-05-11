import Foundation

/// Extracts `--` line comments out of CREATE TABLE / CREATE VIEW DDL stored in `sqlite_master.sql`.
///
/// SQLite preserves comments **inside** the CREATE statement but strips anything before the
/// `CREATE` keyword. To stay predictable:
///
///   * Column description = stacked `--` lines immediately preceding the column definition,
///     OR a trailing `-- …` comment on the same line as the column definition.
///   * Table description = a `--` comment block at the top of the parens, **separated from
///     the first column by a blank line**. Without that blank line, the comments belong to
///     the first column. (This explicit separator avoids ambiguity between "describes the
///     table" and "describes the first column".)
///   * View description = `--` comment block between `AS` and the SELECT body.
///   * Comments before constraint definitions (PRIMARY KEY, FOREIGN KEY, CHECK, …) are
///     dropped — there is no node to attach them to.
public enum DDLCommentParser {
    public struct Result: Sendable, Hashable {
        public let description: String?
        public let columnDescriptions: [String: String]

        public init(description: String?, columnDescriptions: [String: String]) {
            self.description = description
            self.columnDescriptions = columnDescriptions
        }

        public static let empty = Result(description: nil, columnDescriptions: [:])

        public var isEmpty: Bool {
            description == nil && columnDescriptions.isEmpty
        }
    }

    public static func parse(_ sql: String?) -> Result {
        guard let sql, !sql.isEmpty, let body = extractBody(from: sql) else {
            return .empty
        }
        return parseBody(body)
    }

    // MARK: - Body extraction

    private struct Body {
        enum Kind { case table, view }
        let kind: Kind
        let text: String
    }

    private static func extractBody(from sql: String) -> Body? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        if upper.hasPrefix("CREATE TABLE")
            || upper.hasPrefix("CREATE TEMP TABLE")
            || upper.hasPrefix("CREATE TEMPORARY TABLE") {
            guard let openParen = trimmed.firstIndex(of: "(") else { return nil }
            let after = trimmed.index(after: openParen)
            guard let close = matchingClose(in: trimmed, from: after) else { return nil }
            return Body(kind: .table, text: String(trimmed[after..<close]))
        }

        if upper.hasPrefix("CREATE VIEW")
            || upper.hasPrefix("CREATE TEMP VIEW")
            || upper.hasPrefix("CREATE TEMPORARY VIEW") {
            guard let asRange = trimmed.range(
                of: #"\bAS\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                return nil
            }
            return Body(kind: .view, text: String(trimmed[asRange.upperBound...]))
        }

        return nil
    }

    /// Walks `text` starting at `start` and returns the index of the `)` that closes the
    /// implicit `(` already opened by the caller. Respects nested parens, string literals,
    /// and `--` line comments (so a `)` inside a comment doesn't break depth tracking).
    private static func matchingClose(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var inSingle = false
        var inDouble = false
        var i = start

        while i < text.endIndex {
            let c = text[i]
            if !inSingle && !inDouble {
                if c == "'" {
                    inSingle = true
                } else if c == "\"" {
                    inDouble = true
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { return i }
                } else if c == "-" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "-" {
                        // Skip to end-of-line so a stray `)` in a comment doesn't confuse us.
                        while i < text.endIndex, text[i] != "\n" {
                            i = text.index(after: i)
                        }
                        continue
                    }
                }
            } else if inSingle {
                if c == "'" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "'" {
                        i = next
                    } else {
                        inSingle = false
                    }
                }
            } else if inDouble {
                if c == "\"" { inDouble = false }
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: - Parsing

    private static let constraintKeywords: Set<String> = [
        "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT"
    ]

    private static func parseBody(_ body: Body) -> Result {
        let lines = body.text.components(separatedBy: "\n")
        var pending: [String] = []
        var description: String?
        var columnDescriptions: [String: String] = [:]
        var sawCode = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Blank line. Before the first column, a blank line after a stacked comment block
            // promotes that block to "table description" (intentional separator).
            if line.isEmpty {
                if !sawCode, !pending.isEmpty, description == nil {
                    description = combine(pending)
                    pending.removeAll()
                }
                continue
            }

            // Pure comment line.
            if line.hasPrefix("--") {
                pending.append(stripCommentMarker(line))
                continue
            }

            // For views the first code line ends description capture — view bodies don't
            // have column-defs to attach further comments to.
            if body.kind == .view {
                if description == nil {
                    description = combine(pending)
                }
                return Result(description: description, columnDescriptions: [:])
            }

            let (codePart, trailingComment) = splitTrailingComment(line)
            let code = codePart.trimmingCharacters(in: .whitespacesAndNewlines)

            if code.isEmpty {
                // Just a trailing comment on its own line — treat like a normal comment line.
                if let trailingComment { pending.append(trailingComment) }
                continue
            }

            sawCode = true
            if let columnName = extractColumnName(from: code) {
                var collected = pending
                if let trailingComment { collected.append(trailingComment) }
                if let joined = combine(collected) {
                    columnDescriptions[columnName] = joined
                }
            }
            pending.removeAll()
        }

        // Views may end without ever hitting a non-comment line (degenerate, but defensive).
        if body.kind == .view, description == nil {
            description = combine(pending)
        }
        return Result(description: description, columnDescriptions: columnDescriptions)
    }

    private static func stripCommentMarker(_ line: String) -> String {
        var s = Substring(line)
        if s.hasPrefix("--") { s = s.dropFirst(2) }
        return String(s).trimmingCharacters(in: .whitespaces)
    }

    private static func combine(_ pieces: [String]) -> String? {
        let joined = pieces.filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Splits a code line at the first unescaped `--`. Strings and double-quoted identifiers
    /// are honored so `'foo -- bar'` doesn't get mistaken for a comment.
    private static func splitTrailingComment(_ line: String) -> (code: String, comment: String?) {
        var inSingle = false
        var inDouble = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if !inSingle && !inDouble {
                if c == "'" {
                    inSingle = true
                } else if c == "\"" {
                    inDouble = true
                } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                    let code = String(chars[0..<i])
                    let comment = String(chars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
                    return (code, comment.isEmpty ? nil : comment)
                }
            } else if inSingle {
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" {
                        i += 1
                    } else {
                        inSingle = false
                    }
                }
            } else if inDouble {
                if c == "\"" { inDouble = false }
            }
            i += 1
        }
        return (line, nil)
    }

    /// Returns the column name from a line like `email TEXT NOT NULL`. Returns nil when the
    /// line is a table-level constraint (PRIMARY KEY, FOREIGN KEY, CHECK, etc.).
    private static func extractColumnName(from code: String) -> String? {
        var rest = Substring(code)
        while rest.first == "," || rest.first == " " || rest.first == "\t" {
            rest = rest.dropFirst()
        }
        guard let first = rest.first else { return nil }

        if first == "\"" {
            return extractQuoted(rest.dropFirst(), terminator: "\"", allowDoubling: true)
        }
        if first == "`" {
            return extractQuoted(rest.dropFirst(), terminator: "`", allowDoubling: false)
        }
        if first == "[" {
            return extractQuoted(rest.dropFirst(), terminator: "]", allowDoubling: false)
        }

        var end = rest.startIndex
        while end < rest.endIndex {
            let c = rest[end]
            if c.isWhitespace || c == "(" || c == "," { break }
            end = rest.index(after: end)
        }
        let identifier = String(rest[rest.startIndex..<end])
        guard !identifier.isEmpty else { return nil }
        if constraintKeywords.contains(identifier.uppercased()) { return nil }
        return identifier
    }

    private static func extractQuoted(
        _ rest: Substring,
        terminator: Character,
        allowDoubling: Bool
    ) -> String? {
        var i = rest.startIndex
        var result = ""
        while i < rest.endIndex {
            let c = rest[i]
            if c == terminator {
                let next = rest.index(after: i)
                if allowDoubling, next < rest.endIndex, rest[next] == terminator {
                    result.append(c)
                    i = rest.index(after: next)
                    continue
                }
                return result.isEmpty ? nil : result
            }
            result.append(c)
            i = rest.index(after: i)
        }
        return nil
    }
}
