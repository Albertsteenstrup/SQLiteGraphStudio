import CoreGraphics
import Testing
@testable import StudioCore

@MainActor
struct GraphOverviewAnchorsTests {
    @Test func anchorEnlargesTheExistingNodeAroundItsCenter() {
        let original = CGRect(x: 100, y: 80, width: 23, height: 5)
        let anchor = GraphOverviewAnchors.frame(for: original, title: "contract")
        #expect(anchor.midX == original.midX && anchor.midY == original.midY)
        #expect(anchor.width >= 52 && anchor.height == 20)
        #expect(anchor.contains(original))
    }

    @Test func anchorNeverShrinksANodeAndLongNamesRemainBounded() {
        let wide = CGRect(x: 10, y: 20, width: 220, height: 40)
        #expect(GraphOverviewAnchors.frame(for: wide, title: "contract") == wide)
        let long = GraphOverviewAnchors.frame(
            for: CGRect(x: 0, y: 0, width: 3, height: 3),
            title: String(repeating: "long_table_name_", count: 20)
        )
        #expect(long.width == 180)
        #expect(long.height == 20)
    }

    @Test func enlargedNodeIsTheRelationEndpointAndTopmostHitTarget() throws {
        let cache = GraphInteractionGeometryCache()
        let frames = [
            "contract": CGRect(x: 100, y: 100, width: 24, height: 6),
            "neighbor": CGRect(x: 128, y: 100, width: 7, height: 6),
        ]
        let anchors = [GraphOverviewAnchors.Anchor(id: "contract", title: "contract")]
        func snapshot(_ zoom: CGFloat, anchors: [GraphOverviewAnchors.Anchor]) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 400, height: 300),
                           zoom: zoom, isLarge: true, emphasized: [], contentRevision: 0,
                           overviewAnchors: anchors, roleForNode: { _ in .collapsedNode },
                           descriptorForNode: { _ in nil })
        }
        let original = snapshot(0.2, anchors: [])
        let anchored = snapshot(0.2, anchors: anchors)
        let enlarged = try #require(anchored.markerFrames["contract"])
        #expect(enlarged.midX == original.markerFrames["contract"]?.midX)
        #expect(enlarged.width > original.markerFrames["contract"]!.width)
        #expect(anchored.anchorMap.nodeCards["contract"]?.frame == enlarged)
        #expect(anchored.topmostHit(at: CGPoint(x: 130, y: 103), zIndexForNode: { _ in 0 },
                                   nodeIndexForNode: { $0 == "neighbor" ? 1 : 0 }) == "contract")
        #expect(snapshot(0.2, anchors: anchors).revision == anchored.revision)
        #expect(snapshot(0.2, anchors: [.init(id: "contract", title: "new name")]).revision != anchored.revision)

        let transition = snapshot(0.6, anchors: anchors)
        #expect(transition.renderPlan.markerIDs.contains("contract"))
        let detailed = snapshot(0.8, anchors: anchors)
        #expect(detailed.renderPlan.detailIDs.contains("contract"))
        #expect(detailed.markerFrames["contract"] == nil)
    }
}
