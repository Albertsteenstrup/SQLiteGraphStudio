import Foundation

/// The SQL flavour a migration set is written in. It decides how unqualified
/// names are resolved and whether identifiers fold to lower case.
public enum SQLDialect: String, Sendable, Hashable, Codable, CaseIterable {
    case postgreSQL
    case sqlite

    public var displayName: String {
        switch self {
        case .postgreSQL:
            return "PostgreSQL"
        case .sqlite:
            return "SQLite"
        }
    }

    /// PostgreSQL resolves unqualified names against a schema; SQLite has none.
    var defaultSchema: String? {
        switch self {
        case .postgreSQL:
            return "public"
        case .sqlite:
            return nil
        }
    }

    /// PostgreSQL folds unquoted identifiers to lower case. SQLite keeps the
    /// declared spelling and compares case-insensitively.
    func fold(_ identifier: String, quoted: Bool) -> String {
        guard !quoted else { return identifier }
        switch self {
        case .postgreSQL:
            return identifier.lowercased()
        case .sqlite:
            return identifier
        }
    }
}

/// Splits a script into statements without interpreting them. Comments, string
/// literals, dollar-quoted bodies and quoted identifiers never terminate a
/// statement, so a `;` inside a PL/pgSQL body stays with its own block.
enum SQLScript {
    static func statements(in sql: String) -> [String] {
        let characters = Array(sql)
        var statements: [String] = []
        var index = 0
        var start = 0

        func appendStatement(upTo end: Int) {
            let text = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { statements.append(text) }
        }

        while index < characters.count {
            switch characters[index] {
            case "-" where character(characters, index + 1) == "-":
                index = skipLineComment(characters, from: index)
            case "/" where character(characters, index + 1) == "*":
                index = skipBlockComment(characters, from: index)
            case "'":
                index = skipQuoted(characters, from: index, delimiter: "'",
                                   allowsBackslashEscapes: isEscapeStringStart(characters, at: index))
            case "\"":
                index = skipQuoted(characters, from: index, delimiter: "\"", allowsBackslashEscapes: false)
            case "`":
                index = skipQuoted(characters, from: index, delimiter: "`", allowsBackslashEscapes: false)
            case "$":
                index = dollarQuoteRange(characters, from: index)?.upperBound ?? (index + 1)
            case ";":
                appendStatement(upTo: index)
                index += 1
                start = index
            default:
                index += 1
            }
        }
        appendStatement(upTo: characters.count)
        return statements
    }

    // MARK: - Lexical helpers shared with the tokenizer

    static func character(_ characters: [Character], _ index: Int) -> Character? {
        index >= 0 && index < characters.count ? characters[index] : nil
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    /// `--` runs to the end of the line.
    static func skipLineComment(_ characters: [Character], from index: Int) -> Int {
        var cursor = index + 2
        while cursor < characters.count, !characters[cursor].isNewline { cursor += 1 }
        return cursor
    }

    /// PostgreSQL block comments nest.
    static func skipBlockComment(_ characters: [Character], from index: Int) -> Int {
        var cursor = index + 2
        var depth = 1
        while cursor < characters.count, depth > 0 {
            if characters[cursor] == "/", character(characters, cursor + 1) == "*" {
                depth += 1
                cursor += 2
            } else if characters[cursor] == "*", character(characters, cursor + 1) == "/" {
                depth -= 1
                cursor += 2
            } else {
                cursor += 1
            }
        }
        return cursor
    }

    /// Returns the index just past the closing delimiter. A doubled delimiter is
    /// an escaped delimiter, not a terminator.
    static func skipQuoted(_ characters: [Character], from index: Int, delimiter: Character,
                           allowsBackslashEscapes: Bool) -> Int {
        var cursor = index + 1
        while cursor < characters.count {
            let current = characters[cursor]
            if allowsBackslashEscapes, current == "\\" {
                cursor += 2
                continue
            }
            if current == delimiter {
                if character(characters, cursor + 1) == delimiter {
                    cursor += 2
                    continue
                }
                return cursor + 1
            }
            cursor += 1
        }
        return characters.count
    }

    /// `E'…'` and `e'…'` honour backslash escapes.
    static func isEscapeStringStart(_ characters: [Character], at index: Int) -> Bool {
        guard let previous = character(characters, index - 1), previous == "E" || previous == "e" else { return false }
        guard let beforePrevious = character(characters, index - 2) else { return true }
        return !isIdentifierCharacter(beforePrevious)
    }

    /// The full `$tag$ … $tag$` span, or nil when this `$` is a parameter
    /// placeholder or part of an identifier.
    static func dollarQuoteRange(_ characters: [Character], from index: Int) -> Range<Int>? {
        if let previous = character(characters, index - 1), isIdentifierCharacter(previous) { return nil }
        var cursor = index + 1
        var tag = ""
        while cursor < characters.count, characters[cursor] != "$" {
            let current = characters[cursor]
            let valid = tag.isEmpty ? isIdentifierStart(current) : isIdentifierCharacter(current)
            guard valid, current != "$" else { return nil }
            tag.append(current)
            cursor += 1
        }
        guard cursor < characters.count else { return nil }
        let opener = Array("$\(tag)$")
        var search = cursor + 1
        while search + opener.count <= characters.count {
            if Array(characters[search..<(search + opener.count)]) == opener {
                return index..<(search + opener.count)
            }
            search += 1
        }
        // An unterminated body runs to the end rather than resyncing mid-literal.
        return index..<characters.count
    }
}
