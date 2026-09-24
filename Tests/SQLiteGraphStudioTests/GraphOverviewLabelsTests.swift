import CoreGraphics
import Testing
@testable import StudioCore

struct GraphOverviewLabelsTests {
    @Test func nearbyAnchorsGetNonOverlappingLabels() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
        let markers = [
            CGRect(x: 140, y: 95, width: 8, height: 5),
            CGRect(x: 147, y: 95, width: 8, height: 5),
            CGRect(x: 154, y: 95, width: 8, height: 5),
        ]
        let placements = GraphOverviewLabels.place(markers.enumerated().map { index, marker in
            .init(id: "table\(index)", marker: marker, labelSize: CGSize(width: 75, height: 20))
        }, in: viewport)
        #expect(placements.count == 3)
        for (index, placement) in placements.enumerated() {
            #expect(viewport.insetBy(dx: 8, dy: 8).contains(placement.label))
            #expect(!placements.prefix(index).contains { $0.label.insetBy(dx: -4, dy: -4).intersects(placement.label) })
        }
    }

    @Test func offscreenOrOversizedAnchorsDoNotCoverTheMap() {
        let placements = GraphOverviewLabels.place([
            .init(id: "offscreen", marker: CGRect(x: 500, y: 50, width: 5, height: 5),
                  labelSize: CGSize(width: 50, height: 20)),
            .init(id: "oversized", marker: CGRect(x: 50, y: 50, width: 5, height: 5),
                  labelSize: CGSize(width: 500, height: 20)),
        ], in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(placements.isEmpty)
    }
}
