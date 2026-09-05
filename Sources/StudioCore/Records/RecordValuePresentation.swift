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
    /// Validates JSON syntax and changes only whitespace, preserving exact tokens.
    /// Invalid, cancelled, or oversized formatting returns the original raw value.
    /// Work is bounded to 2 MiB of input, 8 MiB of output, and 128 container levels.
    public static func formattedJSON(_ raw: String) async -> String {
        guard !Task.isCancelled else { return raw }
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                guard raw.utf8.count <= BoundedJSONFormatter.maximumInputBytes else { return raw }
                var formatter = BoundedJSONFormatter(bytes: Array(raw.utf8))
                return try formatter.format()
            } catch {
                return raw
            }
        }
        return await withTaskCancellationHandler {
            let result = await worker.value
            return Task.isCancelled ? raw : result
        } onCancel: {
            worker.cancel()
        }
    }
}

/// A bounded byte parser avoids constructing a JSON object tree or Character array.
/// Token slices are copied verbatim; only JSON's four whitespace bytes are replaced.
private struct BoundedJSONFormatter {
    static let maximumInputBytes = 2 * 1024 * 1024
    private static let maximumOutputBytes = 8 * 1024 * 1024
    private static let maximumDepth = 128
    private enum Failure: Error { case invalid, limit }
    let bytes: [UInt8]
    private var index = 0
    private var output: [UInt8] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func format() throws -> String {
        output.reserveCapacity(min(bytes.count * 2, Self.maximumOutputBytes))
        try value(depth: 0)
        try whitespace()
        guard index == bytes.count else { throw Failure.invalid }
        try Task.checkCancellation()
        return String(decoding: output, as: UTF8.self)
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func advance() throws {
        index += 1
        if index % 4096 == 0 { try Task.checkCancellation() }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard current == byte else { throw Failure.invalid }
        try advance()
    }

    private mutating func whitespace() throws {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
            try advance()
        }
    }

    private mutating func append(_ byte: UInt8) throws {
        guard output.count < Self.maximumOutputBytes else { throw Failure.limit }
        output.append(byte)
    }

    private mutating func appendToken(from start: Int) throws {
        guard index - start <= Self.maximumOutputBytes - output.count else { throw Failure.limit }
        output.append(contentsOf: bytes[start..<index])
    }

    private mutating func newline(depth: Int) throws {
        let count = 1 + depth * 2
        guard count <= Self.maximumOutputBytes - output.count else { throw Failure.limit }
        output.append(0x0a)
        output.append(contentsOf: repeatElement(UInt8(0x20), count: depth * 2))
    }

    private mutating func value(depth: Int) throws {
        try Task.checkCancellation()
        try whitespace()
        guard let byte = current else { throw Failure.invalid }
        switch byte {
        case 0x7b: try container(object: true, depth: depth)
        case 0x5b: try container(object: false, depth: depth)
        case 0x22: try string()
        case 0x74: try literal([0x74, 0x72, 0x75, 0x65])
        case 0x66: try literal([0x66, 0x61, 0x6c, 0x73, 0x65])
        case 0x6e: try literal([0x6e, 0x75, 0x6c, 0x6c])
        case 0x2d, 0x30...0x39: try number()
        default: throw Failure.invalid
        }
    }

    private mutating func container(object: Bool, depth: Int) throws {
        guard depth < Self.maximumDepth else { throw Failure.limit }
        let opening: UInt8 = object ? 0x7b : 0x5b
        let closing: UInt8 = object ? 0x7d : 0x5d
        try consume(opening)
        try append(opening)
        try whitespace()
        if current == closing {
            try advance()
            try append(closing)
            return
        }
        while true {
            try newline(depth: depth + 1)
            if object {
                try whitespace()
                try string()
                try whitespace()
                try consume(0x3a)
                try append(0x3a)
                try append(0x20)
            }
            try value(depth: depth + 1)
            try whitespace()
            if current == closing {
                try advance()
                try newline(depth: depth)
                try append(closing)
                return
            }
            try consume(0x2c)
            try append(0x2c)
        }
    }

    private mutating func string() throws {
        let start = index
        try consume(0x22)
        while let byte = current {
            if byte == 0x22 {
                try advance()
                try appendToken(from: start)
                return
            }
            guard byte >= 0x20 else { throw Failure.invalid }
            try advance()
            if byte == 0x5c {
                guard let escape = current else { throw Failure.invalid }
                try advance()
                switch escape {
                case 0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74: break
                case 0x75:
                    for _ in 0..<4 {
                        guard let hex = current, (0x30...0x39).contains(hex) || (0x41...0x46).contains(hex) || (0x61...0x66).contains(hex) else { throw Failure.invalid }
                        try advance()
                    }
                default: throw Failure.invalid
                }
            }
        }
        throw Failure.invalid
    }

    private mutating func literal(_ token: [UInt8]) throws {
        let start = index
        for byte in token { try consume(byte) }
        try appendToken(from: start)
    }

    private mutating func digits() throws {
        let start = index
        while let byte = current, (0x30...0x39).contains(byte) { try advance() }
        guard index > start else { throw Failure.invalid }
    }

    private mutating func number() throws {
        let start = index
        if current == 0x2d { try advance() }
        if current == 0x30 { try advance() }
        else { try digits() }
        if current == 0x2e {
            try advance()
            try digits()
        }
        if current == 0x65 || current == 0x45 {
            try advance()
            if current == 0x2b || current == 0x2d { try advance() }
            try digits()
        }
        try appendToken(from: start)
    }
}
