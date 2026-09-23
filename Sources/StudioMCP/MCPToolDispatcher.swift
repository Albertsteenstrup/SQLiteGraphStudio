import Foundation

public struct MCPToolCall {
    public let name: String
    public let arguments: [String: Any]
    public let contextID: String?
    public let clientID: String
    public let clientName: String?
    public let clientVersion: String?
    public let workingDirectory: String

    public init(
        name: String,
        arguments: [String: Any],
        contextID: String?,
        clientID: String,
        clientName: String?,
        clientVersion: String?,
        workingDirectory: String
    ) {
        self.name = name
        self.arguments = arguments
        self.contextID = contextID
        self.clientID = clientID
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.workingDirectory = workingDirectory
    }
}

public protocol MCPToolDispatcher {
    /// Returns an MCP CallToolResult object (`content`, and optionally
    /// `structuredContent` and `isError`).
    func dispatch(_ call: MCPToolCall) -> [String: Any]
    /// Called when the stdio client terminates so app-side state can be released.
    func clientDisconnected(clientID: String)
}

public extension MCPToolDispatcher {
    func clientDisconnected(clientID: String) {}
}
