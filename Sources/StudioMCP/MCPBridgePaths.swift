import AppKit
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

    /// Running Graph Studio apps. Hidden review renderers share the app's bundle but never
    /// show a window, hold the single-instance lock or answer the bridge, so they are left
    /// out: a renderer must never pass for the app.
    public static func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
            .filter { $0.activationPolicy != .prohibited }
    }
}
