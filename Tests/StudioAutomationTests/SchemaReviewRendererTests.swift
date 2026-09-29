import AppKit
import Foundation
@testable import StudioCore
@testable import StudioMCP
import Testing

/// Drives Graph Studio's real renderer process the way the inline review view does: the
/// helper starts it from a clone of the app executable and sends the reader's input.
struct SchemaReviewRendererTests {
    @Test func selectedReviewCardHasNoOuterHalo() throws {
        let executable = try #require(Self.appExecutable(), "The SQLiteGraphStudio product is built for this test target")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-border-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var review = Self.review()
        review.before.tables.removeAll { $0.id != "users" }
        review.after.tables.removeAll { $0.id != "users" }
        review.before.relations = []
        review.after.relations = []
        let url = folder.appendingPathComponent("change.sgreview")
        try review.write(to: url)
        let renderer = SchemaReviewRenderer(executableProvider: { executable },
                                            slotDirectory: folder.appendingPathComponent("slots", isDirectory: true),
                                            cloneDirectory: folder.appendingPathComponent("clones", isDirectory: true),
                                            idleTimeout: 60)
        defer { renderer.stop() }

        let request: [String: Any] = ["cmd": "render", "path": url.path, "width": 800, "height": 500,
                                      "scale": 1, "appearance": "light", "format": "png"]
        _ = try renderer.request(request)
        var selectedRequest = request
        selectedRequest["actions"] = [["type": "select", "table": "users"]]
        let selected = try renderer.request(selectedRequest)
        #expect(selected["selection"] as? [String] == ["users"])
        let imageData = try #require(Data(base64Encoded: selected["image"] as? String ?? ""))
        let image = try #require(NSBitmapImageRep(data: imageData))
        let midY = image.pixelsHigh / 2
        func rgb(at x: Int) -> NSColor? { image.colorAt(x: x, y: midY)?.usingColorSpace(.deviceRGB) }
        let borderX = try #require((50..<(image.pixelsWide / 2)).first { x in
            guard let color = rgb(at: x) else { return false }
            return color.blueComponent - color.redComponent > 0.08
                && color.blueComponent - color.greenComponent > 0.04
        }, "The selected review card should have a blue border")
        let outside = try #require(rgb(at: borderX - 3))
        let background = try #require(rgb(at: borderX - 40))
        #expect(abs(outside.redComponent - background.redComponent) * 255 <= 3,
                "The review card should not darken the canvas outside its blue border")
    }

    @Test func drawsTheAppsGraphAndAnswersReaderInput() throws {
        let executable = try #require(Self.appExecutable(), "The SQLiteGraphStudio product is built for this test target")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let review = Self.review()
        let url = folder.appendingPathComponent("change.sgreview")
        try review.write(to: url)
        let renderer = SchemaReviewRenderer(executableProvider: { executable },
                                            slotDirectory: folder.appendingPathComponent("slots", isDirectory: true),
                                            cloneDirectory: folder.appendingPathComponent("clones", isDirectory: true),
                                            idleTimeout: 60)
        defer { renderer.stop() }

        func frame(_ actions: [[String: Any]] = []) throws -> (image: NSBitmapImageRep, state: [String: Any]) {
            let result = SchemaReviewAppTools.frame(arguments: ["path": url.path, "width": 480, "height": 320, "scale": 1,
                                                                "actions": actions],
                                                    workingDirectory: "/", renderer: renderer)
            try #require(result["isError"] as? Bool == false, "\(result["structuredContent"] ?? result)")
            let content = try #require((result["content"] as? [[String: Any]])?.first)
            let data = try #require(Data(base64Encoded: content["data"] as? String ?? ""))
            let image = try #require(NSBitmapImageRep(data: data))
            return (image, result["structuredContent"] as? [String: Any] ?? [:])
        }

        let opened = try frame()
        #expect(opened.image.pixelsWide == 480 && opened.image.pixelsHigh == 320)
        #expect(opened.state["setTables"] as? [[String]] == review.changeSets)
        #expect(opened.state["set"] is NSNull, "Framing the first set does not select it")
        #expect((opened.state["selection"] as? [String])?.isEmpty == true)

        // Exercise the merged graph gesture path with a real synthetic click on the
        // visible users marker, rather than only selecting a table by ID.
        let clicked = try frame([["type": "click", "x": 240, "y": 227]])
        #expect(clicked.state["selection"] as? [String] == ["users"])

        let stepped = try frame([["type": "step", "direction": 1]])
        #expect(stepped.state["set"] as? Int == 1)

        let linked = try frame([["type": "select", "table": "users"]])
        #expect(linked.state["set"] as? Int == 0)
        #expect(linked.state["selection"] as? [String] == ["users"])

        // An empty corner is canvas: the app's own tap handling shows every change again.
        let cleared = try frame([["type": "click", "x": 4, "y": 316]])
        #expect(cleared.state["set"] is NSNull)
        #expect((cleared.state["selection"] as? [String])?.isEmpty == true)

        let jumped = try frame([["type": "set", "index": 0], ["type": "transform", "scale": 1.5, "tx": -120, "ty": -80]])
        #expect(jumped.state["set"] as? Int == 0)
        #expect(renderer.isRunning)

        // Preview iteration replaces the file at the same path while the helper lives.
        // The next frame must draw that new review instead of reusing its old session.
        var revised = review
        revised.after.tables.removeAll { $0.id == "audits" }
        try revised.write(to: url)
        let reloaded = try frame()
        #expect(reloaded.state["setTables"] as? [[String]] == revised.changeSets)
        #expect(reloaded.state["sets"] as? Int == 1)
    }

    private final class Marker {}

    /// The app executable sits beside this test bundle in the build products.
    private static func appExecutable() -> URL? {
        let candidate = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SQLiteGraphStudio")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Two connected sets: users with its team, and an unrelated new audit table.
    private static func review() -> SchemaReviewDocument {
        func column(_ name: String, _ type: String = "TEXT", notNull: Bool = false, pk: Int = 0) -> SchemaReviewSnapshot.Column {
            .init(name: name, type: type, notNull: notNull, defaultSQL: nil, primaryKeyOrdinal: pk, generated: 0, identity: "")
        }
        func table(_ id: String, _ columns: [SchemaReviewSnapshot.Column]) -> SchemaReviewSnapshot.Table {
            .init(id: id, schema: nil, name: id, kind: "table", columns: [column("id", "INTEGER", pk: 1)] + columns, metadata: [:])
        }
        let relation = SchemaReviewSnapshot.Relation(id: "fk_team", source: "users", target: "teams", sourceColumns: ["team_id"],
                                                     targetColumns: ["id"], definition: "FOREIGN KEY (team_id) REFERENCES teams(id)")
        return SchemaReviewDocument(title: "Renderer", baseRef: "a", headRef: "b",
            before: SchemaReviewSnapshot(engine: "sqlite", tables: [
                table("teams", [column("name")]), table("users", [column("team_id", "INTEGER"), column("email")]),
            ], relations: [relation]),
            after: SchemaReviewSnapshot(engine: "sqlite", tables: [
                table("teams", [column("name", notNull: true)]), table("users", [column("team_id", "INTEGER"), column("email"), column("active")]),
                table("audits", [column("action")]),
            ], relations: [relation]))
    }
}
