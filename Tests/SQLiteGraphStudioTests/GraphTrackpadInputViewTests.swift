import AppKit
import SwiftUI
import Testing
@testable import StudioCore

@MainActor
@Suite(.serialized)
struct GraphTrackpadInputViewTests {
    @Test
    func metadataPanelCanBeDismissedWithoutLosingDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.sqlite")
        try SchemaSidecarStore.save(SchemaSidecar(tables: ["missing": .init(description: "Note")]), for: url)
        let defaultsName = "GraphTrackpadInputViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let session = AppSession(userDefaults: defaults)
        defer { session.closeDatabase() }
        session.apply(snapshot: CatalogSnapshot(descriptors: [], graph: .empty), target: .sqlite(url))
        let originalDiagnostics = session.metadataDiagnostics
        #expect(!originalDiagnostics.isEmpty)

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudioRootView(session: session)
            .transaction { $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try #require(await waitUntil { self.hasExclusionRegion(in: window.contentView) })
        let panel = try #require(exclusionRegion(in: window.contentView))
        let closePoint = panel.convert(NSPoint(x: panel.bounds.maxX - 24, y: panel.bounds.maxY - 24), to: nil)
        try click(closePoint, in: window)
        try #require(await waitUntil { !self.hasExclusionRegion(in: window.contentView) })
        #expect(session.metadataDiagnostics == originalDiagnostics)

        // An unchanged reload must not bring back a panel the user dismissed.
        session.reloadSchemaSidecarFromDisk()
        #expect(!hasExclusionRegion(in: window.contentView))

        try SchemaSidecarStore.save(SchemaSidecar(tables: ["other_missing": .init(description: "New note")]), for: url)
        session.reloadSchemaSidecarFromDisk()
        try #require(await waitUntil { self.hasExclusionRegion(in: window.contentView) })
        #expect(session.metadataDiagnostics != originalDiagnostics)
    }

    @Test(arguments: [GraphTestEvent.Kind.trackpad, .wheel, .magnify])
    func panelGesturesPassThroughWithoutMovingTheGraph(kind: GraphTestEvent.Kind) {
        let (window, graph, panel) = fixture()
        defer { window.close() }
        var panCount = 0
        var zoomCount = 0
        graph.onPan = { _ in panCount += 1 }
        graph.onMagnify = { _, _ in zoomCount += 1 }

        let overPanel = GraphTestEvent(kind: kind, window: window, point: NSPoint(x: 120, y: 70))
        #expect(graph.handleEvent(overPanel) === overPanel)
        #expect(panCount == 0)
        #expect(zoomCount == 0)

        let overGraph = GraphTestEvent(kind: kind, window: window, point: NSPoint(x: 50, y: 70))
        #expect(graph.handleEvent(overGraph) == nil)
        #expect(panCount == (kind == .trackpad ? 1 : 0))
        #expect(zoomCount == (kind == .trackpad ? 0 : 1))

        // Dismissing the panel immediately returns its area to graph input.
        panel.removeFromSuperview()
        #expect(graph.handleEvent(overPanel) == nil)
        #expect(panCount == (kind == .trackpad ? 2 : 0))
        #expect(zoomCount == (kind == .trackpad ? 0 : 2))
    }

    @Test
    func exclusionsFollowPanelGeometryAndVisibility() {
        let (window, graph, panel) = fixture()
        defer { window.close() }
        var panCount = 0
        graph.onPan = { _ in panCount += 1 }
        let event = GraphTestEvent(kind: .trackpad, window: window, point: NSPoint(x: 120, y: 70))
        #expect(graph.handleEvent(event) === event)

        panel.setFrameOrigin(NSPoint(x: 250, y: 50))
        #expect(graph.handleEvent(event) == nil)
        #expect(panCount == 1)

        panel.setFrameOrigin(NSPoint(x: 100, y: 50))
        panel.isHidden = true
        #expect(graph.handleEvent(event) == nil)
        #expect(panCount == 2)

        panel.isHidden = false
        #expect(graph.handleEvent(event) === event)
        #expect(panCount == 2)
    }

    @Test
    func panelInAnotherWindowDoesNotBlockGraphInput() {
        let (window, graph, panel) = fixture()
        let otherWindow = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { window.close(); otherWindow.close() }
        otherWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        panel.removeFromSuperview()
        otherWindow.contentView?.addSubview(panel)
        var panCount = 0
        graph.onPan = { _ in panCount += 1 }

        let event = GraphTestEvent(kind: .trackpad, window: window, point: NSPoint(x: 120, y: 70))
        #expect(graph.handleEvent(event) == nil)
        #expect(panCount == 1)
        #expect(panel.hitTest(NSPoint(x: 20, y: 20)) == nil)
    }

    private func fixture() -> (NSWindow, GraphTrackpadInputView, GraphInputExclusionRegion.RegionView) {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: frame)
        window.contentView = root
        let graph = GraphTrackpadInputView(frame: frame)
        root.addSubview(graph)
        let panel = GraphInputExclusionRegion.RegionView(frame: NSRect(x: 100, y: 50, width: 150, height: 80))
        root.addSubview(panel)
        return (window, graph, panel)
    }

    private func hasExclusionRegion(in view: NSView?) -> Bool {
        exclusionRegion(in: view) != nil
    }

    private func exclusionRegion(in view: NSView?) -> GraphInputExclusionRegion.RegionView? {
        guard let view else { return nil }
        if let region = view as? GraphInputExclusionRegion.RegionView { return region }
        for child in view.subviews {
            if let region = exclusionRegion(in: child) { return region }
        }
        return nil
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// Supplies native event properties to the same handler the local monitor uses.
/// This avoids posting synthetic input to the user's active application.
final class GraphTestEvent: NSEvent {
    enum Kind: Sendable { case trackpad, wheel, magnify }
    private let kind: Kind
    private let targetWindow: NSWindow
    private let point: NSPoint

    init(kind: Kind, window: NSWindow, point: NSPoint) {
        self.kind = kind
        self.targetWindow = window
        self.point = point
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var window: NSWindow? { targetWindow }
    override var type: NSEvent.EventType { kind == .magnify ? .magnify : .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { 15 }
    override var hasPreciseScrollingDeltas: Bool { kind == .trackpad }
    override var magnification: CGFloat { 0.25 }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}
