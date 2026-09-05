import Foundation

public enum RecordValuePresentation {
    public static func raw(_ value: SQLiteValue) -> String {
        if case .blob(let data) = value { return data.map { String(format: "%02x", $0) }.joined() }
        return value.editorText
    }
    public static func summary(_ value: SQLiteValue) -> String {
        if case .null = value { return "NULL" }
        if case .blob(let data) = value { return "Binary · \(data.count.formatted()) bytes" }
        let text = raw(value)
        if text.isEmpty { return "Empty text" }
        return String(text.prefix(512)) + (text.utf8.count > 512 ? "…" : "")
    }
    /// Lexical whitespace formatting preserves numeric precision, duplicate keys and escapes.
    public static func formattedJSON(_ raw: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let data = raw.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return raw }
            var output = "", depth = 0, quoted = false, escaped = false
            let chars = Array(raw)
            for (index, char) in chars.enumerated() {
                if index % 4096 == 0 && Task.isCancelled { return raw }
                if quoted {
                    output.append(char)
                    if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { quoted = false }
                    continue
                }
                switch char {
                case "\"": quoted = true; output.append(char)
                case "{", "[": depth += 1; output.append(char); output += "\n" + String(repeating: "  ", count: depth)
                case "}", "]": depth = max(0, depth - 1); output += "\n" + String(repeating: "  ", count: depth); output.append(char)
                case ",": output += ",\n" + String(repeating: "  ", count: depth)
                case ":": output += ": "
                default: if !char.isWhitespace { output.append(char) }
                }
            }
            return output
        }.value
    }
}
