import AppKit
import GRDB
import SwiftUI
import Testing
@testable import StudioCore

@MainActor
@Suite(.serialized)
struct WorkspaceInteractionTests {
    @Test
    func hoveredConnectedCardOpensItsTableWhenItOverlapsTheRoot() async throws {
        let url = try TestSupport.createFixture(named: "overlapping-hover")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let relatedID = "posts_with_a_long_related_table_name_that_overlaps_the_expanded_root"
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in
            try db.execute(sql: "ALTER TABLE posts RENAME TO \(relatedID)")
        }
        try database.close()
        let defaultsName = "OverlappingGraphHover.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        defer { session.closeDatabase() }
        session.graph = SchemaGraph(nodes: session.graph.nodes.filter { ["authors", relatedID].contains($0.id) },
            edges: session.graph.edges.filter { $0.sourceID == relatedID && $0.targetID == "authors" })
        session.graphLayout.pin(nodeID: "authors", at: .zero)
        session.graphLayout.pin(nodeID: relatedID, at: CGPoint(x: 2_000, y: 0))

        let window = GraphInteractionTestWindow(contentRect: NSRect(x: -2000, y: -2000, width: 840, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: SchemaGraphView(session: session).transaction { $0.disablesAnimations = true })
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let initial = try #require(session.automationGraphNodeFrames["authors"])
        session.requestGraphTap(at: CGPoint(x: initial.midX, y: initial.midY))
        try await Task.sleep(for: .milliseconds(250))
        session.markAutomationViewChanged()
        try await Task.sleep(for: .milliseconds(150))
        let resting = try #require(session.automationGraphNodeFrames[relatedID])
        let observer = try #require(graphObserver(in: root))
        func movePointer(to point: CGPoint) throws {
            window.pointerLocation = root.convert(point, to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: window.pointerLocation, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            _ = observer.handleEvent(event)
        }
        try movePointer(to: CGPoint(x: resting.midX, y: resting.midY))
        try await Task.sleep(for: .milliseconds(150))
        session.markAutomationViewChanged()
        try await Task.sleep(for: .milliseconds(150))
        let hovered = try #require(session.automationGraphNodeFrames[relatedID])
        let expanded = try #require(session.automationGraphNodeFrames["authors"])
        let overlap = hovered.intersection(expanded)
        try #require(!overlap.isEmpty, "The long hovered card must cover part of the root in this fixture")
        let point = CGPoint(x: overlap.midX, y: overlap.midY)
        try movePointer(to: point)
        try await Task.sleep(for: .milliseconds(150))
        session.markAutomationViewChanged()
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.automationGraphNodeFrames[relatedID]?.width == hovered.width,
                "Moving into the overlap must retain the foreground card's hover")
        let windowPoint = root.convert(point, to: nil)
        try click(windowPoint, in: window)
        try await Task.sleep(for: .milliseconds(60))
        try click(windowPoint, in: window, count: 2)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        #expect(session.openTabs.map { $0.descriptor.name } == [relatedID],
                "The visible foreground card must receive the double-click instead of the root")
        #expect(session.activePaneSide == .right)
    }

    @Test(arguments: [CGFloat(0.05), 0.8], [1, 2])
    func graphSingleAndDoubleClicksHaveDistinctActions(zoom: CGFloat, clicks: Int) async throws {
        let url = try TestSupport.createFixture(named: "graph-double-click")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaultsName = "GraphDoubleClick.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        defer { session.closeDatabase() }
        session.rendersOffscreen = true
        session.graph = SchemaGraph(nodes: session.graph.nodes.filter { ["authors", "posts"].contains($0.id) }, edges: [])
        session.graphLayout.pin(nodeID: "authors", at: .zero)
        session.graphLayout.pin(nodeID: "posts", at: CGPoint(x: 2_000, y: 0))

        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: SchemaGraphView(session: session).transaction { $0.disablesAnimations = true })
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        session.graphZoom = zoom
        session.graphPan = .zero
        session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        session.markAutomationViewChanged()
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
        let authors = try #require(session.automationGraphNodeFrames["authors"])
        #expect((authors.width < 40) == (zoom < 0.1), "Exercise both canvas markers and drawn SwiftUI cards")
        let authorPoint = root.convert(CGPoint(x: authors.midX, y: authors.midY), to: nil)
        try click(authorPoint, in: window)
        if clicks == 2 {
            try await Task.sleep(for: .milliseconds(60))
            try click(authorPoint, in: window, count: 2)
        }
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        if clicks == 2 {
            #expect(session.openTabs.map { $0.descriptor.name } == ["authors"])
            #expect(session.activePaneSide == .right)
            #expect(session.paneState(for: .right).kind == .tables)
            #expect(session.expandedGraphNodeIDs.isEmpty, "A double-click must open the original table before it is moved into focus")
        } else {
            #expect(session.expandedGraphNodeIDs == ["authors"], "A single click must still inspect the graph card")
            #expect(session.openTabs.isEmpty)
        }
    }

    @Test
    func graphInputObserverPassesClicksToUnderlyingControls() async throws {
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 600, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = root
        var clickCount = 0
        let button = NSHostingView(rootView: Button {
            clickCount += 1
        } label: {
            Text("Filter").frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain))
        button.frame = NSRect(x: 250, y: 230, width: 100, height: 40)
        root.addSubview(button)
        let observer = GraphTrackpadInputView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        root.addSubview(observer)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))

        try click(NSPoint(x: 300, y: 250), in: window)
        #expect(clickCount == 1)
    }

    @Test
    func openTableButtonReceivesMouseClicksWithTheMinimapVisible() async throws {
        let url = try TestSupport.createFixture(named: "workspace-interaction")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaultsName = "WorkspaceInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        defer { session.closeDatabase() }
        #expect(!session.isRefreshing)
        #expect(session.graphVisuals.isEnabled(.minimap))

        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: StudioRootView(session: session).transaction { $0.disablesAnimations = true })
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 895, y: root.bounds.height - 510)
        try click(point, in: window)
        try await Task.sleep(for: .milliseconds(100))
        let pickerPresented = session.isTablePickerPresented
        #expect(pickerPresented)
    }

    private func click(_ point: NSPoint, in window: NSWindow, count: Int = 1) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: count, clickCount: count, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func graphObserver(in view: NSView) -> GraphTrackpadInputView? {
        if let observer = view as? GraphTrackpadInputView { return observer }
        for child in view.subviews {
            if let observer = graphObserver(in: child) { return observer }
        }
        return nil
    }
}

/// Keep geometry refreshes on the test pointer without moving the user's cursor.
@MainActor
private final class GraphInteractionTestWindow: NSWindow {
    var pointerLocation = NSPoint(x: -10_000, y: -10_000)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}
