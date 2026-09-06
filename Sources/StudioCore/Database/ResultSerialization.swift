import Foundation

/// Shared wire-independent export contract. Names are labels, never identities.
public enum ResultSerialization {
    public static func uniqueNames(_ names: [String]) -> [String] {
        let reserved = Set(names)
        var used: Set<String> = []
        return names.map { name in
            if used.insert(name).inserted { return name }
            var suffix = 2
            while reserved.contains("\(name)_\(suffix)") || used.contains("\(name)_\(suffix)") { suffix += 1 }
            let unique = "\(name)_\(suffix)"
            used.insert(unique)
            return unique
        }
    }

    public static func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) throws -> String {
        try serialize(names: result.columns.map(\.name), rows: result.rows.map(\.values), format: format)
    }

    public static func serializeTableRows(descriptor: TableDescriptor, rows: [TableRow], format: DataTransferFormat) throws -> String {
        try serialize(names: descriptor.columns.map(\.name), rows: rows.map(\.values), format: format)
    }

    static func serialize(names: [String], rows: [[DatabaseResultValue]], format: DataTransferFormat) throws -> String {
        let keys = uniqueNames(names)
        switch format {
        case .csv:
            return try ([names.map { csvText($0) }.joined(separator: ",")] + rows.map { try row($0, keys: keys, format: .csv) }).joined(separator: "\n")
        case .json:
            return "[" + (try rows.map { try row($0, keys: keys, format: .json) }).joined(separator: ",\n") + "]"
        }
    }

    static func row(_ values: [DatabaseResultValue], keys: [String], format: DataTransferFormat) throws -> String {
        guard values.count == keys.count else {
            throw DatabaseUserError(kind: .invalidInput, message: "Export row has \(values.count) values for \(keys.count) columns.")
        }
        switch format {
        case .csv: return values.map(csvValue).joined(separator: ",")
        case .json:
            let object = Dictionary(uniqueKeysWithValues: zip(keys, values.map(jsonValue)))
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
    }

    static func csvText(_ value: String, forceQuote: Bool = false) -> String {
        guard forceQuote || value.isEmpty || value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func csvValue(_ value: DatabaseResultValue) -> String {
        if value == .null { return "\\N" }
        let text = exactText(value)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quoting distinguishes text from current and legacy import NULL markers,
        // and keeps whitespace-only records from looking like blank CSV lines.
        return csvText(text, forceQuote: text == "\\N" || trimmed.uppercased() == "NULL" || trimmed.isEmpty)
    }

    public static func exactText(_ value: DatabaseResultValue) -> String {
        switch value {
        case .null: return "NULL"
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .text(let value), .exactNumeric(let value), .uuid(let value), .dateTime(let value), .json(let value), .array(let value): return value
        case .blob(let data): return data.base64EncodedString()
        }
    }

    private static func jsonValue(_ value: DatabaseResultValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let value): return value
        case .double(let value): return value.isFinite ? value as Any : String(value)
        case .boolean(let value): return value
        default: return exactText(value)
        }
    }
}
