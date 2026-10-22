import Foundation

/// Packaged apps and their helper load resources beside the installed executable,
/// before SwiftPM's build-directory fallback is evaluated.
enum MCPResourceBundle {
    private static let name = "SQLiteGraphStudio_StudioMCP.bundle"

    static let bundle: Bundle = packagedBundle(
        executableURL: Bundle.main.executableURL, resourceURL: Bundle.main.resourceURL
    ) ?? Bundle.module

    static func packagedBundle(executableURL: URL?, resourceURL: URL?) -> Bundle? {
        let besideExecutable = executableURL?
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        for directory in [resourceURL, besideExecutable].compactMap({ $0 }) {
            if let bundle = Bundle(url: directory.appendingPathComponent(name, isDirectory: true)) {
                return bundle
            }
        }
        return nil
    }
}
