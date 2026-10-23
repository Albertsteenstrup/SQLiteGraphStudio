import AppKit
import Foundation
@testable import StudioCore
import Testing

@Suite(.serialized)
struct NativeFocusRegressionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_NATIVE_FOCUS_MIGRATIONS"] != nil,
                   "Requires an isolated copy of the reported migration model")) @MainActor
    func migrationModelFocusFitsTheNativeSplitPane() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let folder = try #require(ProcessInfo.processInfo.environment["SGS_NATIVE_FOCUS_MIGRATIONS"])
        let rootID = ProcessInfo.processInfo.environment["SGS_NATIVE_FOCUS_TABLE"] ?? "public.vendor"
        let suite = "NativeMigrationFocus.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppSession(userDefaults: defaults)
        await source.openMigrations(at: URL(fileURLWithPath: folder), version: nil)
        let neighbours = source.graph.neighbors(of: rootID).subtracting([rootID])
        #expect(neighbours.count > 16)
        source.graphNodeSizeMetric = .fields
        source.graphZoom = 0.05
        source.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        source.markAutomationViewChanged()
        let renderer = try WorkspaceGraphRenderer()
        defer { renderer.close() }
        renderer.synchronize(from: source, revision: "native-migration-focus", width: 840, height: 700)
        _ = try await settledFrame(renderer)
        try renderer.apply(["type": "select", "table_id": rootID])
        let image = try await settledFrame(renderer)
        if let directory = ProcessInfo.processInfo.environment["SGS_SPOTLIGHT_EVIDENCE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try image.image.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-vendor-focus.png"))
        }
        let rootFrame = try frame(rootID, in: renderer)
        print("NATIVE_FOCUS tables=\(source.graph.nodes.count) neighbours=\(neighbours.count) zoom=\(renderer.zoom) root=\(rootFrame)")
        #expect(rootFrame.width <= 360)
        #expect(abs(rootFrame.midX - 420) <= 60)
        for id in neighbours {
            let frame = try frame(id, in: renderer)
            #expect(CGRect(x: 0, y: 0, width: 840, height: 700).contains(frame))
            #expect(frame.width >= 100)
        }
        await source.closeAndWait()
    }

    @Test @MainActor
    func fieldSizedCatalogKeepsFocusedNeighboursNearTheCard() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-focus-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let suite = "NativeFocusRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppSession(userDefaults: defaults)
        await source.openDatabase(url: file)
        let root = try #require(source.graph.node(id: "posts"))
        let neighbours = (0..<21).map { GraphNode(id: "related_\($0)", title: "related_\($0)", isEditable: false) }
        let background = (0..<371).map { GraphNode(id: "background_\($0)", title: "background_\($0)", isEditable: false) }
        source.graph = SchemaGraph(nodes: [root] + neighbours + background, edges: neighbours.map {
            GraphEdge(id: $0.id, sourceID: $0.id, targetID: root.id, sourceColumn: "post_id", targetColumn: "id")
        })
        source.tables = [TableSummary(name: root.id, objectType: .table, isEditable: false, columnCount: 50, rowCount: nil)]
            + neighbours.map { TableSummary(name: $0.id, objectType: .table, isEditable: false, columnCount: 12, rowCount: nil) }
            + background.map { TableSummary(name: $0.id, objectType: .table, isEditable: false, columnCount: 71, rowCount: nil) }
        source.graphNodeSizeMetric = .fields
        var positions = [root.id: CGPoint(x: -3_000, y: 0)]
        for (index, node) in (neighbours + background).enumerated() {
            positions[node.id] = CGPoint(x: -3_000 + (index % 20) * 240, y: (index / 20) * 90)
        }
        source.graphLayout.restore(.init(positions: positions, pinnedPositions: [:]), for: source.graph,
                                   presentation: .compact, descriptorLookup: source.descriptor(named:))
        source.graphZoom = 0.05
        source.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        source.markAutomationViewChanged()
        let original = source.graphLayout.snapshot(for: source.graph)
        let renderer = try WorkspaceGraphRenderer()
        defer { renderer.close() }
        renderer.synchronize(from: source, revision: "native-sized-catalog", width: 840, height: 700)
        _ = try await settledFrame(renderer)
        try renderer.apply(["type": "select", "table_id": root.id])
        let image = try await settledFrame(renderer)
        if let directory = ProcessInfo.processInfo.environment["SGS_SPOTLIGHT_EVIDENCE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let folder = URL(fileURLWithPath: directory)
            try image.image.write(to: folder.appendingPathComponent("native-field-sized-focus.png"))
            try JSONSerialization.data(withJSONObject: ["zoom": renderer.zoom, "panX": renderer.pan.width,
                "panY": renderer.pan.height, "nodes": renderer.nodes], options: [.prettyPrinted])
                .write(to: folder.appendingPathComponent("native-field-sized-focus.json"))
        }
        let rootFrame = try frame(root.id, in: renderer)
        #expect(rootFrame.width <= 360, "The expanded card must leave room for surrounding tables in the split pane")
        #expect(abs(rootFrame.midX - 420) <= 60, "The focused card must stay centred with its neighbours")
        for neighbour in neighbours {
            let frame = try frame(neighbour.id, in: renderer)
            #expect(CGRect(x: 0, y: 0, width: 840, height: 700).contains(frame))
            #expect(frame.width >= 100, "A connected table must remain visible rather than shrinking to an overview dot")
        }
        #expect(source.graphLayout.snapshot(for: source.graph) == original)
        await source.closeAndWait()
    }

    @MainActor private func settledFrame(_ renderer: WorkspaceGraphRenderer) async throws -> WorkspaceGraphRenderer.Frame {
        for attempt in 0..<3 {
            do { return try await renderer.render() }
            catch WorkspaceGraphRenderer.RenderError.unavailable where attempt < 2 { await Task.yield() }
        }
        throw WorkspaceGraphRenderer.RenderError.unavailable
    }

    @MainActor private func frame(_ id: String, in renderer: WorkspaceGraphRenderer) throws -> CGRect {
        let node = try #require(renderer.nodes.first { $0["table_id"] as? String == id })
        return CGRect(x: try #require(node["x"] as? CGFloat), y: try #require(node["y"] as? CGFloat),
                      width: try #require(node["width"] as? CGFloat), height: try #require(node["height"] as? CGFloat))
    }
}
