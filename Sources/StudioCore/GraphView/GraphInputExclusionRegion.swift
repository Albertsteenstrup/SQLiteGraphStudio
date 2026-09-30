import AppKit
import SwiftUI

/// Marks a floating panel whose gestures belong to its controls, even when a
/// graph's window-level event monitor covers the same coordinates.
struct GraphInputExclusionRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ nsView: RegionView, context: Context) {}

    @MainActor
    static func contains(_ point: NSPoint, in window: NSWindow) -> Bool {
        RegionView.regions.allObjects.contains { region in
            let localPoint = region.convert(point, from: nil)
            return region.window === window
                && !region.isHiddenOrHasHiddenAncestor
                && region.bounds.contains(localPoint)
                && region.visibleRect.contains(localPoint)
        }
    }

    final class RegionView: NSView {
        fileprivate static let regions = NSHashTable<RegionView>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.regions.add(self) }
            else { Self.regions.remove(self) }
        }

        // The marker must leave ordinary AppKit/SwiftUI hit testing untouched.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
