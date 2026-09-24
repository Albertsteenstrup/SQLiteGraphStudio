import AppKit
import CoreGraphics
import Foundation

/// Important overview tables remain nodes at their graph coordinates. Their
/// markers grow enough to contain a name instead of gaining detached callouts.
enum GraphOverviewAnchors {
    struct Anchor: Hashable {
        let id: String
        let title: String
    }

    static let minimumZoom: CGFloat = 0.10
    static let cardTransitionZoom: CGFloat = 0.78

    static func frame(for marker: CGRect, title: String) -> CGRect {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let measuredWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let readableWidth = min(180, max(52, ceil(measuredWidth) + 12))
        let width = max(marker.width, readableWidth)
        let height = max(marker.height, 20)
        return CGRect(x: marker.midX - width / 2, y: marker.midY - height / 2,
                      width: width, height: height)
    }
}
