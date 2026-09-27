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

    private func hostedWorkspace() -> (AppSession, NSWindow) {
        let session = AppSession(databaseService: DatabaseService())
        session.apply(
            snapshot: CatalogSnapshot(descriptors: [], graph: .empty),
            target: .sqlite(URL(fileURLWithPath: "/tmp/workspace-split-layout.sqlite"))
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1200, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
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
