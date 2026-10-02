import AppKit
import Foundation
@testable import StudioCore
import Testing

@Suite(.serialized)
struct WorkspaceGraphContextLayoutTests {
    @Test @MainActor
    func readerContextUsesAuthoredModelPositionsAndRestoresMovedDetail() async throws {
        try await withSource { source in
            let renderer = try WorkspaceGraphRenderer()
            defer { renderer.close() }
            let authoredPosition = CGPoint(x: 1_200, y: -200)
            source.graphLayout.pin(nodeID: "posts", at: authoredPosition)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "complete-model", width: 900, height: 440)
            _ = try await renderer.render()

            source.setAutomationVisibleTableIDs(["authors", "posts"])
            source.compactGraphTables(["authors", "posts"], columns: 2)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "compact-detail", width: 900, height: 440)
            _ = try await renderer.render()
            try renderer.apply(["type": "expand", "table_id": "posts"])
            let movedPosition = CGPoint(x: 310, y: 70)
            try renderer.apply(["type": "move", "table_id": "posts", "x": movedPosition.x, "y": movedPosition.y])
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == movedPosition)
            let inspectedZoom = renderer.zoom, inspectedPan = renderer.pan
            let sourceDetail = source.graphLayout.snapshot(for: source.graph)

            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            #expect(renderer.contextMode && renderer.visibleTables.count == source.graph.nodes.count)
            #expect(try center("posts", in: renderer) == authoredPosition,
                    "The highlighted table must return to its complete-model cluster, rather than keep a detail drag")
            #expect(source.graphLayout.snapshot(for: source.graph) == sourceDetail,
                    "Embedded context must not reposition the native source workspace")

            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            #expect(Set(renderer.visibleTables) == ["authors", "posts"])
            #expect(try center("posts", in: renderer) == movedPosition)
            #expect(renderer.selection == ["posts"] && renderer.expandedTables == ["posts"])
            #expect(renderer.zoom == inspectedZoom && renderer.pan == inspectedPan)
            #expect(source.graphLayout.snapshot(for: source.graph) == sourceDetail)

            // A later author instruction takes control from context. It must not
            // revive the reader's earlier saved detail or use its dragged layout.
            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            let nextAuthoredPosition = CGPoint(x: -180, y: 40)
            source.setAutomationVisibleTableIDs(["posts"])
            source.graphLayout.pin(nodeID: "posts", at: nextAuthoredPosition)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "next-authored-detail", width: 900, height: 440)
            _ = try await renderer.render()
            #expect(!renderer.contextMode && renderer.visibleTables == ["posts"])
            #expect(try center("posts", in: renderer) == nextAuthoredPosition)
        }
    }

    @Test @MainActor
    func authoredContextRestoresModelOnEntryAndThenHonorsArrangement() async throws {
        try await withSource { source in
            let renderer = try WorkspaceGraphRenderer()
            defer { renderer.close() }
            let modelPosition = CGPoint(x: 1_200, y: -200)
            source.graphLayout.pin(nodeID: "posts", at: modelPosition)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "complete-model", width: 900, height: 440)
            _ = try await renderer.render()
            source.setAutomationVisibleTableIDs(["authors", "posts"])
            source.compactGraphTables(["authors", "posts"], columns: 2)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "detail", width: 900, height: 440)
            _ = try await renderer.render()

            source.graphContextTableIDs = ["authors", "posts"]
            source.setAutomationVisibleTableIDs(nil)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "authored-context", width: 900, height: 440)
            _ = try await renderer.render()
            #expect(renderer.contextMode && renderer.visibleTables.count == source.graph.nodes.count)
            #expect(try center("posts", in: renderer) == modelPosition,
                    "An agent's broader-context step must place subjects in their original complete model")

            let authoredZoom = renderer.zoom * 1.02
            let authoredPan = CGSize(width: renderer.pan.width + 15, height: renderer.pan.height + 7)
            source.graphZoom = authoredZoom
            source.graphPan = authoredPan
            source.setGraphSelection(["posts"])
            source.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "camera-only-active-context", width: 900, height: 440)
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == modelPosition,
                    "Camera and selection instructions must not recopy still-compacted source positions")
            #expect(renderer.zoom == authoredZoom && renderer.pan == authoredPan && renderer.selection == ["posts"])

            let arrangedPosition = CGPoint(x: 900, y: -100)
            source.graphLayout.pin(nodeID: "posts", at: arrangedPosition)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "arranged-active-context", width: 900, height: 440)
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == arrangedPosition,
                    "The baseline must not repeatedly override later authored arrangement in active context")
            #expect(source.graphLayout.position(for: "posts") == arrangedPosition)
        }
    }

    @Test(arguments: [GraphNodeSizeMetric.uniform, .relations]) @MainActor
    func directDetailHasStableFullModelFallbackUntilAuthoredModelArrives(metric: GraphNodeSizeMetric) async throws {
        try await withSource { source in
            source.graphNodeSizeMetric = metric
            source.setAutomationVisibleTableIDs(["authors", "posts"])
            source.compactGraphTables(["authors", "posts"], columns: 2)
            let renderer = try WorkspaceGraphRenderer()
            defer { renderer.close() }
            renderer.synchronize(from: source, revision: "direct-detail", width: 900, height: 440)
            _ = try await renderer.render()
            let movedPosition = CGPoint(x: 320, y: 60)
            try renderer.apply(["type": "move", "table_id": "posts", "x": movedPosition.x, "y": movedPosition.y])
            _ = try await renderer.render()

            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            let fallbackPosition = try center("posts", in: renderer)
            #expect(fallbackPosition != movedPosition)
            #expect(renderer.visibleTables.count == source.graph.nodes.count)
            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == movedPosition)
            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == fallbackPosition,
                    "Reader context reuses a stable full-model fallback across inspections")

            source.setAutomationVisibleTableIDs(nil)
            let authoredPosition = CGPoint(x: 1_000, y: -100)
            source.graphLayout.pin(nodeID: "posts", at: authoredPosition)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "first-authored-model", width: 900, height: 440)
            _ = try await renderer.render()
            source.setAutomationVisibleTableIDs(["authors", "posts"])
            source.compactGraphTables(["authors", "posts"], columns: 2)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "later-detail", width: 900, height: 440)
            _ = try await renderer.render()
            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == authoredPosition,
                    "The first authored complete model supersedes generated fallback positions")
        }
    }

    @Test @MainActor
    func nativeMetricClearancePreservesReaderContextAndExactDetailReturn() async throws {
        try await withSource { source in
            // Exercise the native metric path on a settled layout, as happens
            // when the desktop zooms out while the embedded card is inspected.
            source.restoreAutomationGraphLayout(source.graphLayout.snapshot(for: source.graph))
            source.graphNodeSizeMetric = .relations
            let authoredPosition = CGPoint(x: 1_200, y: -200)
            source.graphLayout.pin(nodeID: "posts", at: authoredPosition)
            source.markAutomationViewChanged()
            let renderer = try WorkspaceGraphRenderer()
            defer { renderer.close() }
            renderer.synchronize(from: source, revision: "metric-complete-model", width: 900, height: 440)
            _ = try await renderer.render()

            source.setAutomationVisibleTableIDs(["authors", "posts"])
            source.compactGraphTables(["authors", "posts"], columns: 2)
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "metric-detail", width: 900, height: 440)
            _ = try await renderer.render()
            try renderer.apply(["type": "expand", "table_id": "posts"])
            let movedPosition = CGPoint(x: 310, y: 70)
            try renderer.apply(["type": "move", "table_id": "posts", "x": movedPosition.x, "y": movedPosition.y])
            let inspected = try await renderer.render()
            let detailZoom = renderer.zoom, detailPan = renderer.pan
            #expect(try center("posts", in: renderer) == movedPosition)

            try renderer.apply(["type": "context"])
            _ = try await renderer.render()
            #expect(try center("posts", in: renderer) == authoredPosition)
            try renderer.apply(["type": "transform", "tx": 21, "ty": 13])
            _ = try await renderer.render()
            let contextZoom = renderer.zoom, contextPan = renderer.pan
            let nativeBefore = source.graphLayout.snapshot(for: source.graph)
            let sizingRevision = source.graphNodeSizingLayoutRevision
            let renderRevision = source.automationViewRevision
            source.graphZoom = 0.005
            source.resizeGraphNodesForCurrentMetric(minimumZoom: source.graphZoom)
            let nativeAfter = source.graphLayout.snapshot(for: source.graph)
            #expect(nativeAfter != nativeBefore, "The fixture must reach actual native metric clearance")
            #expect(source.graphNodeSizingLayoutRevision == sizingRevision &+ 1)
            #expect(source.automationViewRevision == renderRevision &+ 1,
                    "Automatic sizing must still invalidate the native render receipt")

            renderer.synchronize(from: source, revision: "native-metric-clearance", width: 900, height: 440)
            _ = try await renderer.render()
            #expect(renderer.contextMode && renderer.visibleTables.count == source.graph.nodes.count)
            #expect(Set(renderer.highlightedTables) == ["authors", "posts"])
            #expect(renderer.zoom == contextZoom && renderer.pan == contextPan)
            #expect(try center("posts", in: renderer) == authoredPosition)
            #expect(source.graphLayout.snapshot(for: source.graph) == nativeAfter,
                    "Embedded synchronization must preserve native metric clearance")

            try renderer.apply(["type": "context"])
            let returned = try await renderer.render()
            #expect(!renderer.contextMode && Set(renderer.visibleTables) == ["authors", "posts"])
            #expect(renderer.selection == ["posts"] && renderer.expandedTables == ["posts"])
            #expect(try center("posts", in: renderer) == movedPosition)
            #expect(renderer.zoom == detailZoom && renderer.pan == detailPan)
            #expect(returned.image == inspected.image,
                    "Metric inspection must return to the exact detail pixels, positions, and camera")

            source.setAutomationVisibleTableIDs(["posts"])
            source.graphLayout.pin(nodeID: "posts", at: CGPoint(x: -160, y: 40))
            source.markAutomationViewChanged()
            renderer.synchronize(from: source, revision: "authored-after-native-sizing", width: 900, height: 440)
            _ = try await renderer.render()
            #expect(renderer.visibleTables == ["posts"] && !renderer.contextMode,
                    "A subsequent authored instruction must still replace reader inspection")
            #expect(try center("posts", in: renderer) == CGPoint(x: -160, y: 40))
        }
    }

    @MainActor private func center(_ id: String, in renderer: WorkspaceGraphRenderer) throws -> CGPoint {
        let node = try #require(renderer.nodes.first { $0["table_id"] as? String == id })
        return CGPoint(x: try #require(node["center_x"] as? CGFloat),
                       y: try #require(node["center_y"] as? CGFloat))
    }

    @MainActor private func withSource(_ body: (AppSession) async throws -> Void) async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("context-layout-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let suite = "WorkspaceGraphContextLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppSession(userDefaults: defaults)
        await source.openDatabase(url: file)
        do {
            try await body(source)
            await source.closeAndWait()
        } catch {
            await source.closeAndWait()
            throw error
        }
    }
}
