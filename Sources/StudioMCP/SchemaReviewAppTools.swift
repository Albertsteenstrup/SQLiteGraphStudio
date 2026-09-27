import Foundation

/// Tools the inline review view calls on the reader's behalf. Their `_meta.ui.visibility`
/// is `["app"]`, so hosts that render MCP Apps keep them out of the model's tool list. They
/// are listed for every client: Claude Code doesn't declare the MCP Apps extension, so a
/// client's capabilities can't tell whether its views will call them.
public enum SchemaReviewAppTools {
    public static let frameToolName = "studio_review_frame"
    public static let detailToolName = "studio_review_detail"
    public static let openToolName = "studio_open_review_in_app"
    public static let names: Set<String> = [frameToolName, detailToolName, openToolName]

    /// Draws the review with Graph Studio's own graph view after applying the reader's
    /// clicks, pans, zooms and change-set steps, and returns the frame as an image.
    static func frame(arguments: [String: Any], workingDirectory: String, renderer: SchemaReviewRenderer) -> [String: Any] {
        do {
            let url = try SchemaReviewInlineView.resolve(arguments["path"] as? String ?? "", workingDirectory: workingDirectory)
            let expectedRevision = arguments["revision"] as? String
            if let expectedRevision {
                try SchemaReviewInlineView.requireRevision(expectedRevision,
                                                            current: SchemaReviewInlineView.fileRevision(at: url))
            }
            var request: [String: Any] = ["cmd": "render", "path": url.path]
            // Without an appearance the frame follows the system, as Graph Studio does.
            if let appearance = arguments["appearance"] as? String { request["appearance"] = appearance }
            for key in ["width", "height", "scale"] {
                if let value = arguments[key] as? NSNumber { request[key] = value }
            }
            if let actions = arguments["actions"] as? [[String: Any]] { request["actions"] = actions }
            let response = try renderer.request(request)
            if let expectedRevision {
                try SchemaReviewInlineView.requireRevision(expectedRevision,
                                                            current: SchemaReviewInlineView.fileRevision(at: url))
            }
            guard let image = response["image"] as? String, let mimeType = response["mimeType"] as? String else {
                throw SchemaReviewRenderer.RendererError.failed("The renderer returned no image.")
            }
            var state: [String: Any] = [:]
            for key in ["width", "height", "sets", "setTables", "set", "selection"] {
                state[key] = response[key] ?? NSNull()
            }
            return [
                "content": [["type": "image", "data": image, "mimeType": mimeType]],
                "structuredContent": state,
                "isError": false,
            ]
        } catch let error as SchemaReviewInlineView.InlineReviewError {
            return errorResult(code: error.code, message: error.message)
        } catch let error as SchemaReviewRenderer.RendererError {
            return errorResult(code: error.code, message: error.message)
        } catch {
            return errorResult(code: "RENDERER_FAILED", message: error.localizedDescription)
        }
    }

    /// Sends the review and its original schema to Graph Studio. macOS acknowledges the
    /// open request, but the app can still decline a tab when its document limit is full.
    static func openInApp(arguments: [String: Any], workingDirectory: String, open: ([URL]) throws -> Void) -> [String: Any] {
        do {
            let url = try SchemaReviewInlineView.resolve(arguments["path"] as? String ?? "", workingDirectory: workingDirectory)
            _ = try SchemaReviewInlineView.load(url)
            let original = try writeOriginal(of: url)
            try open([url, original])
            return [
                "content": [["type": "text", "text": "Sent \(url.lastPathComponent) and its original schema to Graph Studio. Check the app to confirm both tabs opened."]],
                "structuredContent": ["requested": [url.path, original.path]],
                "isError": false,
            ]
        } catch let error as SchemaReviewInlineView.InlineReviewError {
            return errorResult(code: error.code, message: error.message)
        } catch let error as OpenError {
            return errorResult(code: error.code, message: error.message)
        } catch {
            return errorResult(code: "APP_LAUNCH_FAILED", message: "Graph Studio could not open the review: \(error.localizedDescription)")
        }
    }

    /// A comparison of the review's starting schema with itself: Graph Studio shows it as
    /// the original schema with nothing changed. The path depends only on the review's path,
    /// so opening the same review again reuses (and refreshes) the same file.
    static func writeOriginal(of url: URL, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              let before = document["before"]
        else {
            throw SchemaReviewInlineView.InlineReviewError.invalidArtifact("This is not a Graph Studio schema review or proposal file.")
        }
        let title = document["title"] as? String ?? url.deletingPathExtension().lastPathComponent
        document["after"] = before
        document["headRef"] = document["baseRef"]
        document["title"] = "Original · " + String(title.prefix(200))
        document["notes"] = ["The schema before the changes in \(url.lastPathComponent)."]
        // Without a proposal the file is a plain comparison, and without an author it can
        // never replace the review's own tab.
        document.removeValue(forKey: "proposal")
        document.removeValue(forKey: "author")

        let folder = directory
            .appendingPathComponent("SQLiteGraphStudio Originals", isDirectory: true)
            .appendingPathComponent(stableHash(url.path), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (original).sgreview")
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        if (try? Data(contentsOf: destination)) != data {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    /// Opens files in the Graph Studio app this helper belongs to.
    static func openInGraphStudio(_ urls: [URL]) throws {
        guard let app = UnixSocketMCPBridge.findApplication() else {
            throw OpenError(code: "APP_NOT_INSTALLED", message: "SQLite Graph Studio could not be found. Install it in /Applications or ~/Applications, then retry.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.path] + urls.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenError(code: "APP_LAUNCH_FAILED", message: "The macOS open command did not open the review in Graph Studio.")
        }
    }

    struct OpenError: Error {
        let code: String
        let message: String
    }

    /// FNV-1a, so the folder name is the same in every helper process.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func errorResult(code: String, message: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": message]],
            "structuredContent": ["error": ["code": code, "message": message]],
            "isError": true,
        ]
    }
}
