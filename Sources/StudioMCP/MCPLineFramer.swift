import Foundation

public enum MCPLineFramingError: Error, Equatable {
    case messageTooLarge
}

/// Buffers newline-delimited JSON-RPC messages used by MCP's stdio transport.
public struct MCPLineFramer {
    public static let defaultMaximumMessageBytes = 4 * 1024 * 1024

    private var buffer = Data()
    private let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = MCPLineFramer.defaultMaximumMessageBytes) {
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var messages: [Data] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let length = buffer.distance(from: buffer.startIndex, to: newline)
            guard length <= maximumMessageBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw MCPLineFramingError.messageTooLarge
            }

            var message = Data(buffer[..<newline])
            if message.last == 0x0D {
                message.removeLast()
            }
            messages.append(message)
            buffer.removeSubrange(...newline)
        }

        guard buffer.count <= maximumMessageBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw MCPLineFramingError.messageTooLarge
        }
        return messages
    }

    public var hasPartialMessage: Bool { !buffer.isEmpty }
}
