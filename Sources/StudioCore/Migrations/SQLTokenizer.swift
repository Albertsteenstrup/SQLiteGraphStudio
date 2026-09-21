import Foundation

struct SQLToken: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case word
        case quotedIdentifier
        case string
        case number
        case symbol
    }

    let kind: Kind
    /// Identifier or literal payload with quoting removed; the raw slice otherwise.
    let text: String
    /// Upper-cased `text` for `word` tokens so keyword tests stay allocation-free.
    let upper: String
    /// Character offsets into the statement, used to slice original SQL back out.
    let start: Int
    let end: Int

    var isIdentifier: Bool { kind == .word || kind == .quotedIdentifier }
}

/// A statement's characters together with its token stream. Expression details
/// (defaults, CHECK bodies, index predicates) are sliced from the original
/// characters so they keep the author's spelling and spacing.
struct SQLStatementTokens: Sendable {
    let characters: [Character]
    let tokens: [SQLToken]

    init(_ statement: String) {
        let characters = Array(statement)
        self.characters = characters
        self.tokens = SQLStatementTokens.scan(characters)
    }

    /// Source text spanning the half-open token index range.
    func source(_ range: Range<Int>) -> String {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= tokens.count else { return "" }
        let start = tokens[range.lowerBound].start
        let end = tokens[range.upperBound - 1].end
        return String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let symbols = ["::", ":=", "<=", ">=", "<>", "!=", "||", "->>", "->", "#>>", "#>", "@>", "<@", "&&"]

    private static func scan(_ characters: [Character]) -> [SQLToken] {
        var tokens: [SQLToken] = []
        var index = 0

        while index < characters.count {
            let current = characters[index]

            if current.isWhitespace {
                index += 1
                continue
            }
            if current == "-", SQLScript.character(characters, index + 1) == "-" {
                index = SQLScript.skipLineComment(characters, from: index)
                continue
            }
            if current == "/", SQLScript.character(characters, index + 1) == "*" {
                index = SQLScript.skipBlockComment(characters, from: index)
                continue
            }
            if current == "'" {
                let escapes = SQLScript.isEscapeStringStart(characters, at: index)
                let end = SQLScript.skipQuoted(characters, from: index, delimiter: "'", allowsBackslashEscapes: escapes)
                let payload = unwrap(characters, start: index, end: end, delimiter: "'")
                tokens.append(SQLToken(kind: .string, text: payload, upper: "", start: index, end: end))
                index = end
                continue
            }
            if current == "\"" || current == "`" {
                let end = SQLScript.skipQuoted(characters, from: index, delimiter: current, allowsBackslashEscapes: false)
                let payload = unwrap(characters, start: index, end: end, delimiter: current)
                tokens.append(SQLToken(kind: .quotedIdentifier, text: payload, upper: payload.uppercased(), start: index, end: end))
                index = end
                continue
            }
            if current == "$", let range = SQLScript.dollarQuoteRange(characters, from: index) {
                tokens.append(SQLToken(kind: .string, text: dollarBody(characters, range: range),
                                       upper: "", start: range.lowerBound, end: range.upperBound))
                index = range.upperBound
                continue
            }
            if current.isNumber || (current == "." && (SQLScript.character(characters, index + 1)?.isNumber ?? false)) {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." { end += 1 }
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    var exponent = end + 1
                    if exponent < characters.count, characters[exponent] == "+" || characters[exponent] == "-" { exponent += 1 }
                    if exponent < characters.count, characters[exponent].isNumber {
                        end = exponent
                        while end < characters.count, characters[end].isNumber { end += 1 }
                    }
                }
                let text = String(characters[index..<end])
                tokens.append(SQLToken(kind: .number, text: text, upper: "", start: index, end: end))
                index = end
                continue
            }
            if SQLScript.isIdentifierStart(current) {
                var end = index + 1
                while end < characters.count, SQLScript.isIdentifierCharacter(characters[end]) { end += 1 }
                let text = String(characters[index..<end])
                tokens.append(SQLToken(kind: .word, text: text, upper: text.uppercased(), start: index, end: end))
                index = end
                continue
            }

            let remaining = characters.count - index
            if let symbol = symbols.first(where: { candidate in
                candidate.count <= remaining && String(characters[index..<(index + candidate.count)]) == candidate
            }) {
                tokens.append(SQLToken(kind: .symbol, text: symbol, upper: symbol, start: index, end: index + symbol.count))
                index += symbol.count
                continue
            }

            let text = String(current)
            tokens.append(SQLToken(kind: .symbol, text: text, upper: text, start: index, end: index + 1))
            index += 1
        }

        return tokens
    }

    private static func unwrap(_ characters: [Character], start: Int, end: Int, delimiter: Character) -> String {
        guard end - start >= 2 else { return "" }
        let inner = String(characters[(start + 1)..<(end - 1)])
        return inner.replacingOccurrences(of: String(repeating: String(delimiter), count: 2), with: String(delimiter))
    }

    private static func dollarBody(_ characters: [Character], range: Range<Int>) -> String {
        var tagEnd = range.lowerBound + 1
        while tagEnd < characters.count, characters[tagEnd] != "$" { tagEnd += 1 }
        let openerLength = tagEnd - range.lowerBound + 1
        let bodyStart = range.lowerBound + openerLength
        let bodyEnd = max(bodyStart, range.upperBound - openerLength)
        guard bodyStart <= bodyEnd, bodyEnd <= characters.count else { return "" }
        return String(characters[bodyStart..<bodyEnd])
    }
}

/// A forward cursor over one statement's tokens. Every read is tolerant: an
/// unexpected shape leaves the cursor where it was so the caller can report a
/// diagnostic instead of corrupting the model.
struct SQLCursor {
    let stream: SQLStatementTokens
    var index: Int
    /// Exclusive upper bound, so a sub-cursor over one comma-separated element
    /// can never read past its own slice.
    let limit: Int

    init(_ stream: SQLStatementTokens, at index: Int = 0, limit: Int? = nil) {
        self.stream = stream
        self.index = max(0, index)
        self.limit = min(limit ?? stream.tokens.count, stream.tokens.count)
    }

    init(_ stream: SQLStatementTokens, range: Range<Int>) {
        self.init(stream, at: range.lowerBound, limit: range.upperBound)
    }

    var isAtEnd: Bool { index >= limit }
    var remaining: Range<Int> { min(index, limit)..<limit }

    func token(at offset: Int) -> SQLToken? {
        let position = index + offset
        guard position >= 0, position < limit else { return nil }
        return stream.tokens[position]
    }

    func peek(_ offset: Int = 0) -> SQLToken? { token(at: offset) }

    /// Whether the cursor sits on a real `(` punctuation token.
    var isAtOpenParenthesis: Bool {
        guard let token = peek() else { return false }
        return token.kind == .symbol && token.text == "("
    }

    func peekKeyword(_ offset: Int = 0) -> String? {
        guard let token = token(at: offset), token.kind == .word else { return nil }
        return token.upper
    }

    mutating func advance(_ steps: Int = 1) { index = min(index + steps, limit) }

    @discardableResult
    mutating func match(_ keyword: String) -> Bool {
        guard peekKeyword() == keyword else { return false }
        advance()
        return true
    }

    @discardableResult
    mutating func match(_ keywords: [String]) -> Bool {
        for (offset, keyword) in keywords.enumerated() where peekKeyword(offset) != keyword { return false }
        advance(keywords.count)
        return true
    }

    @discardableResult
    mutating func matchSymbol(_ symbol: String) -> Bool {
        guard let token = peek(), token.kind == .symbol, token.text == symbol else { return false }
        advance()
        return true
    }

    /// Consumes an optional `IF EXISTS` / `IF NOT EXISTS` guard.
    mutating func matchExistenceGuard() {
        _ = match(["IF", "NOT", "EXISTS"]) || match(["IF", "EXISTS"])
    }

    /// Reads `a`, `a.b` or `a.b.c` as its unfolded parts.
    mutating func readIdentifierParts() -> [(text: String, quoted: Bool)] {
        guard let first = peek(), first.isIdentifier else { return [] }
        var parts: [(text: String, quoted: Bool)] = [(first.text, first.kind == .quotedIdentifier)]
        advance()
        while let dot = peek(), dot.kind == .symbol, dot.text == ".",
              let next = peek(1), next.isIdentifier {
            parts.append((next.text, next.kind == .quotedIdentifier))
            advance(2)
        }
        return parts
    }

    /// The token index range inside the next parenthesised group, consuming the
    /// whole group including its parentheses.
    mutating func readParenthesizedRange() -> Range<Int>? {
        guard let open = peek(), open.kind == .symbol, open.text == "(" else { return nil }
        var depth = 0
        var cursor = index
        while cursor < limit {
            let token = stream.tokens[cursor]
            if token.kind == .symbol, token.text == "(" { depth += 1 }
            if token.kind == .symbol, token.text == ")" {
                depth -= 1
                if depth == 0 {
                    let inner = (index + 1)..<cursor
                    index = cursor + 1
                    return inner
                }
            }
            cursor += 1
        }
        // Unbalanced input: treat the remainder as the group rather than failing.
        let inner = (index + 1)..<limit
        index = limit
        return inner.lowerBound <= inner.upperBound ? inner : limit..<limit
    }

    /// Splits a token range on separators that are not nested inside
    /// parentheses or brackets. Brackets matter: `array['a', 'b']` and `text[]`
    /// both appear inside column definitions.
    func splitTopLevel(_ range: Range<Int>, separator: String = ",") -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var depth = 0
        var start = range.lowerBound
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let token = stream.tokens[cursor]
            if token.kind == .symbol {
                if token.text == "(" || token.text == "[" { depth += 1 }
                if token.text == ")" || token.text == "]" { depth -= 1 }
                if depth == 0, token.text == separator {
                    if start < cursor { pieces.append(start..<cursor) }
                    start = cursor + 1
                }
            }
            cursor += 1
        }
        if start < range.upperBound { pieces.append(start..<range.upperBound) }
        return pieces
    }

    /// Consumes tokens until a top-level token matches `stop`, leaving the cursor
    /// on the stopping token. Returns the consumed token range.
    mutating func consume(until stop: (SQLToken) -> Bool) -> Range<Int> {
        let start = index
        var depth = 0
        while index < limit {
            let token = stream.tokens[index]
            if token.kind == .symbol, token.text == "(" || token.text == "[" { depth += 1 }
            if token.kind == .symbol, token.text == ")" || token.text == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0, index > start, stop(token) { break }
            index += 1
        }
        return start..<index
    }

    func source(_ range: Range<Int>) -> String { stream.source(range) }
}
