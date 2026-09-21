import CoreGraphics
import Foundation

/// Hover changes screen geometry only; it never feeds back into the saved layout.
enum GraphHoverPresentation {
    static let detailScale: CGFloat = 1.025

    static func cardScale(hovered: Bool, connected: Bool) -> CGFloat {
        hovered ? detailScale : (connected ? 1.015 : 1)
    }

    static func enlarged(_ frame: CGRect, scale: CGFloat) -> CGRect {
        frame.insetBy(dx: -frame.width * (scale - 1) / 2,
                      dy: -frame.height * (scale - 1) / 2)
    }

    static func markerFrame(_ frame: CGRect, hovered: Bool, connected: Bool) -> CGRect {
        // Absolute padding would more than double a tiny overview node.
        enlarged(GraphExploration.markerFrame(for: frame), scale: cardScale(hovered: hovered, connected: connected))
    }

    static func summaryIDs(hoveredID: String?, connectedIDs: Set<String>,
                           markerFrames: [String: CGRect], viewport: CGRect) -> Set<String> {
        guard let hoveredID else { return [] }
        return connectedIDs.union([hoveredID]).filter { id in
            markerFrames[id].map { viewport.intersects($0) } ?? false
        }
    }

    /// The usual one-line header fits inside the existing node. No detached labels,
    /// minimum label size, or extra hit targets can cover neighboring nodes.
    static func summaryFrame(in frame: CGRect, referenceSize: CGSize) -> CGRect {
        guard referenceSize.width > 0, referenceSize.height > 0 else { return .zero }
        let scale = min(frame.width / referenceSize.width, frame.height / referenceSize.height)
        let size = CGSize(width: referenceSize.width * scale, height: referenceSize.height * scale)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
