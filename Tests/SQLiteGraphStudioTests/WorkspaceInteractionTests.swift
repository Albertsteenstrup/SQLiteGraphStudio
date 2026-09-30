import AppKit
import SwiftUI
import Testing
@testable import StudioCore

@MainActor
@Suite(.serialized)
struct WorkspaceInteractionTests {
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

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }
}
