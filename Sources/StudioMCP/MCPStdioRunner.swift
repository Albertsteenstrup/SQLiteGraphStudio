import Foundation
import Darwin

public final class MCPStdioRunner {
    private let server: MCPServer
    private var framer = MCPLineFramer()

    public init(server: MCPServer) {
        self.server = server
    }

    /// Reads MCP's one-JSON-RPC-object-per-line stdio stream. All diagnostics
    /// stay off stdout so the parent client sees only protocol messages.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) throws {
        defer { server.clientDisconnected() }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            // FileHandle.read(upToCount:) may wait for the requested byte count
            // on a pipe. MCP clients send one request and wait for its reply, so
            // a POSIX read must return as soon as any bytes are available.
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(input.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let chunk = Data(bytes[..<count])
            do {
                for message in try framer.append(chunk) {
                    if let response = server.handleMessage(message) {
                        var frame = response
                        frame.append(0x0A)
                        try output.write(contentsOf: frame)
                    }
                }
            } catch MCPLineFramingError.messageTooLarge {
                let response = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": NSNull(),
                    "error": ["code": -32700, "message": "Message exceeds the 4 MiB limit"],
                ])
                var frame = response
                frame.append(0x0A)
                try output.write(contentsOf: frame)
            }
        }
    }
}
