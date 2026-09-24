import CoreGraphics
import Foundation

/// Places a few authored table names on the full-catalog map. It never changes
/// graph coordinates: the labels provide orientation while the ordinary cards
/// remain available when the reader zooms in or narrows the visible set.
enum GraphOverviewLabels {
    struct Candidate {
        let id: String
        let marker: CGRect
        let labelSize: CGSize
    }

    struct Placement {
        let id: String
        let marker: CGRect
        let label: CGRect
    }

    static func place(_ candidates: [Candidate], in viewport: CGRect) -> [Placement] {
        let safeViewport = viewport.insetBy(dx: 8, dy: 8)
        var occupied: [CGRect] = []
        var result: [Placement] = []
        for candidate in candidates {
            let marker = candidate.marker
            let width = candidate.labelSize.width
            let height = candidate.labelSize.height
            guard width > 0, height > 0, width <= safeViewport.width,
                  height <= safeViewport.height, marker.intersects(viewport) else { continue }
            let options = [
                // Group titles sit above their first row, so try below first.
                CGRect(x: marker.midX - width / 2, y: marker.maxY + 5, width: width, height: height),
                CGRect(x: marker.midX - width / 2, y: marker.minY - height - 5, width: width, height: height),
                CGRect(x: marker.maxX + 6, y: marker.midY - height / 2, width: width, height: height),
                CGRect(x: marker.minX - width - 6, y: marker.midY - height / 2, width: width, height: height),
                CGRect(x: marker.midX - width / 2, y: marker.minY - height * 2 - 10, width: width, height: height),
                CGRect(x: marker.midX - width / 2, y: marker.maxY + height + 10, width: width, height: height),
            ]
            guard let label = options.first(where: { frame in
                safeViewport.contains(frame) && !occupied.contains(where: {
                    $0.insetBy(dx: -4, dy: -4).intersects(frame)
                })
            }) else { continue }
            result.append(Placement(id: candidate.id, marker: marker, label: label))
            occupied.append(label)
        }
        return result
    }
}
