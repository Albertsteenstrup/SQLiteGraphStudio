import AppKit
import SwiftUI

/// SwiftUI buttons and the graph canvas do not take AppKit first responder.
/// End this search field's editing when the user clicks elsewhere in its window.
struct SearchFieldFocusDismissal: NSViewRepresentable {
    var isFocused: Bool
    var dismiss: () -> Void

    func makeNSView(context: Context) -> FocusBoundaryView { FocusBoundaryView() }

    func updateNSView(_ view: FocusBoundaryView, context: Context) {
        view.dismiss = dismiss
        view.trackClicks(isFocused)
    }

    static func dismantleNSView(_ view: FocusBoundaryView, coordinator: ()) {
        view.trackClicks(false)
    }

    final class FocusBoundaryView: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func trackClicks(_ enabled: Bool) {
            if let monitor, !enabled {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard enabled, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
                    window.makeFirstResponder(nil)
                    self.dismiss?()
                }
                return event
            }
        }
    }
}
