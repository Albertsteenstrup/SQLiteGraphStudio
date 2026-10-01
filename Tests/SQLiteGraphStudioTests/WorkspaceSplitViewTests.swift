import AppKit
import SwiftUI
import Testing
@testable import StudioCore

@MainActor
@Suite(.serialized)
struct WorkspaceSplitViewTests {
    @Test
    func restoredFractionAndMaximizeChangeTheRenderedPaneWidths() async throws {
        let (session, window) = hostedWorkspace()
        defer { window.close() }

        let initial = try #require(await waitForPaneWidths(in: window))
        #expect(abs(initial.left / (initial.left + initial.right) - 0.6) < 0.03)

        session.workspaceSplitFraction = 0.35
        let resized = await waitUntil {
            guard let widths = paneWidths(in: window) else { return false }
            return abs(widths.left / (widths.left + widths.right) - 0.35) < 0.03
        }
        try #require(resized, "A restored fraction should move the visible divider")
        let beforeWindowResize = try #require(paneWidths(in: window))

        window.setContentSize(NSSize(width: 1600, height: 800))
        let windowResizeKeptSplit = await waitUntil {
            guard let widths = paneWidths(in: window) else { return false }
            return widths.left > beforeWindowResize.left
                && widths.right > beforeWindowResize.right
                && abs(widths.left / (widths.left + widths.right) - 0.35) < 0.03
        }
        try #require(windowResizeKeptSplit, "Resizing the window should preserve the chosen split")

        for side in WorkspacePaneSide.allCases {
            session.toggleMaximizePane(side)
            let filled = await waitUntil {
                let frames = renderedPaneFrames(in: window)
                return frames.count == 1 && frames[0].width > initial.left + initial.right - 30
            }
            #expect(filled, "\(side.rawValue) pane should fill the workspace")

            session.exitMaximizedMode()
            let restored = await waitUntil {
                guard let widths = paneWidths(in: window) else { return false }
                return abs(widths.left / (widths.left + widths.right) - 0.35) < 0.03
            }
            #expect(restored, "The saved split should return after maximizing \(side.rawValue)")
        }
    }

    /// The divider moves with the split it is dragging. Measured in the divider's own coordinate
    /// space, a drag loses whatever distance the divider has already covered once a frame commits
    /// between two pointer events: it trails the pointer at about half speed and, when the pointer
    /// stops, swings back and forth around it.
    @Test
    func draggingTheDividerKeepsPaceWithThePointerAndSettlesWhenItStops() async throws {
        // SwiftUI feeds drag gestures only while the app is active. As an accessory app, a
        // non-activating panel becomes key without taking focus from whatever is in front.
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        defer { application.setActivationPolicy(originalPolicy) }

        let (_, window) = hostedWorkspace(receivesMouse: true)
        defer { window.close() }
        let initial = try #require(await waitForPaneWidths(in: window))
        let grabX = try #require(dividerCenterX(in: window))
        guard window.isKeyWindow else {
            try Test.cancel("Drag gestures reach SwiftUI only in an unlocked, active GUI session")
        }

        try sendMouse(.leftMouseDown, x: grabX, in: window)
        var travel: CGFloat = 0
        var trace: [String] = []
        var worstLag: CGFloat = 0
        for _ in 0..<10 {
            travel += 10
            try sendMouse(.leftMouseDragged, x: grabX + travel, in: window)
            let moved = try #require(paneWidths(in: window)).left - initial.left
            trace.append("\(Int(moved.rounded()))/\(Int(travel))")
            worstLag = max(worstLag, abs(moved - travel))
        }
        // A hand that has stopped still moves a point or so; the divider must not amplify it.
        var worstSwing: CGFloat = 0
        for step in 0..<10 {
            try sendMouse(.leftMouseDragged, x: grabX + travel + CGFloat(step % 2), in: window)
            let moved = try #require(paneWidths(in: window)).left - initial.left
            trace.append("\(Int(moved.rounded()))/\(Int(travel))")
            worstSwing = max(worstSwing, abs(moved - travel))
        }
        try sendMouse(.leftMouseUp, x: grabX + travel, in: window)
        #expect(worstLag < 3, "The divider should stay under the pointer; moved/pointer per event: \(trace)")
        #expect(worstSwing < 3, "A still pointer should leave the divider still; moved/pointer per event: \(trace)")

        // A second drag starts from where the first one left the divider.
        let settled = try #require(paneWidths(in: window))
        let secondGrab = try #require(dividerCenterX(in: window))
        try sendMouse(.leftMouseDown, x: secondGrab, in: window)
        for step in 1...5 {
            try sendMouse(.leftMouseDragged, x: secondGrab - CGFloat(step) * 10, in: window)
        }
        try sendMouse(.leftMouseUp, x: secondGrab - 50, in: window)
        let back = try #require(paneWidths(in: window))
        #expect(abs((settled.left - back.left) - 50) < 3,
                "The second drag should move the divider 50 pt left, not \(settled.left - back.left)")
    }

    private func hostedWorkspace(receivesMouse: Bool = false) -> (AppSession, NSWindow) {
        let session = AppSession(databaseService: DatabaseService())
        session.apply(
            snapshot: CatalogSnapshot(descriptors: [], graph: .empty),
            target: .sqlite(URL(fileURLWithPath: "/tmp/workspace-split-layout.sqlite"))
        )
        let frame = NSRect(x: -2000, y: -2000, width: 1200, height: 800)
        let window: NSWindow = receivesMouse
            ? NSPanel(contentRect: frame, styleMask: [.titled, .resizable, .nonactivatingPanel],
                      backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: StudioRootView(session: session)
                .transaction { $0.disablesAnimations = true }
        )
        window.makeKeyAndOrderFront(nil)
        return (session, window)
    }

    private func waitForPaneWidths(in window: NSWindow) async -> (left: CGFloat, right: CGFloat)? {
        for _ in 0..<50 {
            if let widths = paneWidths(in: window) { return widths }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func paneWidths(in window: NSWindow) -> (left: CGFloat, right: CGFloat)? {
        let frames = renderedPaneFrames(in: window)
        guard frames.count == 2 else { return nil }
        return (frames[0].width, frames[1].width)
    }

    private func dividerCenterX(in window: NSWindow) -> CGFloat? {
        let frames = renderedPaneFrames(in: window)
        guard frames.count == 2 else { return nil }
        return (frames[0].maxX + frames[1].minX) / 2
    }

    /// Delivers one pointer event, then lets a frame commit, as it does between real events.
    private func sendMouse(_ type: NSEvent.EventType, x: CGFloat, in window: NSWindow) throws {
        let point = NSPoint(x: x, y: (window.contentView?.bounds.height ?? 0) / 2)
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        window.sendEvent(event)
        for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date()) }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func renderedPaneFrames(in window: NSWindow) -> [NSRect] {
        window.contentView?.layoutSubtreeIfNeeded()
        // Pane roots are the tall, distinct rendering regions in the hosting
        // view. Ignore their duplicate backing views at the same x position.
        let subviews: [NSView] = window.contentView?.subviews ?? []
        let allFrames: [NSRect] = subviews.map { $0.frame }
        let largeFrames: [NSRect] = allFrames.filter { frame in
            frame.height > 500 && frame.width > 300 && frame.minY > 40
        }
        let frames = largeFrames.sorted { $0.minX < $1.minX }
        var distinct: [NSRect] = []
        for frame in frames {
            if distinct.last.map({ abs($0.minX - frame.minX) < 2 }) == true { continue }
            distinct.append(frame)
        }
        return distinct
    }
}
