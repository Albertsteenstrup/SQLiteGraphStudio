import Darwin
import Foundation

public enum MCPBridgePaths {
    public static let appBundleIdentifier = "com.albertsteenstrup.sqlitegraphstudio"

    public static var runtimeDirectory: URL {
        URL(fileURLWithPath: "/tmp/sgs-mcp-\(getuid())", isDirectory: true)
    }

    public static var socketURL: URL {
        runtimeDirectory.appendingPathComponent("automation.sock", isDirectory: false)
    }

    public static var credentialURL: URL {
        runtimeDirectory.appendingPathComponent("instance.token", isDirectory: false)
    }
}
