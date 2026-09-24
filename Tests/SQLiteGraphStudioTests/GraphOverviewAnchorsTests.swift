import CoreGraphics
import Testing
@testable import StudioCore

@MainActor
struct GraphOverviewAnchorsTests {
    @Test func importantCardsShrinkMoreSlowlyWithoutChangingTheirCenters() {
        let normal = CGRect(x: 100, y: 80, width: 226 * 0.2, height: 46 * 0.2)
        let anchor = GraphOverviewAnchors.frame(for: normal, zoom: 0.2)
        #expect(abs(GraphOverviewAnchors.displayScale(for: 0.2) - 0.7) < 0.0001)
        #expect(anchor.midX == normal.midX && anchor.midY == normal.midY)
        #expect(abs(anchor.width - 226 * 0.7) < 0.0001)
        #expect(abs(anchor.height - 46 * 0.7) < 0.0001)
        #expect(GraphOverviewAnchors.displayScale(for: 0.1) < GraphOverviewAnchors.displayScale(for: 0.2))
        #expect(GraphOverviewAnchors.displayScale(for: 0.08) > 0.4)
        #expect(GraphOverviewAnchors.displayScale(for: 0.6) > GraphOverviewAnchors.displayScale(for: 0.2))
        #expect(GraphOverviewAnchors.displayScale(for: 0.6) < GraphOverviewAnchors.displayScale(for: 0.78))
        #expect(GraphOverviewAnchors.displayScale(for: 0.78) == 0.78)
        #expect(GraphOverviewAnchors.displayScale(for: 1) == 1)
    }

    @Test func importantTableUsesTheActualCardAndItsFrameForEdgesAndHits() throws {
        let cache = GraphInteractionGeometryCache()
        let frames = [
            "contract": CGRect(x: 100, y: 100, width: 226 * 0.2, height: 46 * 0.2),
            "neighbor": CGRect(x: 220, y: 100, width: 7, height: 6),
        ]
        func snapshot(_ zoom: CGFloat, anchors: [GraphOverviewAnchors.Anchor]) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 400, height: 300),
                           zoom: zoom, isLarge: true, emphasized: [], contentRevision: 0,
                           overviewAnchors: anchors, roleForNode: { _ in .collapsedNode },
                           descriptorForNode: { _ in nil })
        }
        let ordinary = snapshot(0.2, anchors: [])
        let anchored = snapshot(0.2, anchors: [.init(id: "contract")])
        let card = try #require(anchored.anchorMap.nodeCards["contract"])
        #expect(ordinary.renderPlan.markerIDs.contains("contract"))
        #expect(anchored.renderPlan.detailIDs.contains("contract"))
        #expect(anchored.markerFrames["contract"] == nil)
        #expect(card.frame == GraphOverviewAnchors.frame(for: frames["contract"]!, zoom: 0.2))
        #expect(anchored.topmostHit(at: CGPoint(x: 170, y: 105), zIndexForNode: { _ in 0 },
                                   nodeIndexForNode: { $0 == "neighbor" ? 1 : 0 }) == "contract")
        #expect(snapshot(0.2, anchors: [.init(id: "contract")]).revision == anchored.revision)
        #expect(snapshot(0.2, anchors: []).revision != anchored.revision)

        let fullMap = snapshot(0.08, anchors: [.init(id: "contract")])
        #expect(fullMap.renderPlan.detailIDs.contains("contract"))
        #expect(fullMap.anchorMap.nodeCards["contract"]!.frame.width > frames["contract"]!.width)

        let transition = snapshot(0.6, anchors: [.init(id: "contract")])
        #expect(transition.renderPlan.detailIDs.contains("contract"))
        let normalZoom = snapshot(0.8, anchors: [.init(id: "contract")])
        #expect(normalZoom.renderPlan.detailIDs.contains("contract"))
        #expect(normalZoom.anchorMap.nodeCards["contract"]?.frame == frames["contract"])
    }
}
