import Foundation
import Testing
@testable import StudioCore

/// Covers what the relation layer paints at each zoom, and the sampling that keeps a
/// large catalog affordable while zoomed out.
struct GraphEdgeLayerPlanTests {
    // MARK: - Mode

    @Test
    func closeUpEveryRelationIsPainted() {
        for showsOverviewRelations in [true, false] {
            for hasHover in [true, false] {
                #expect(GraphEdgeLayerPlan.mode(isOverview: false, isSchemaReview: false,
                                                showsOverviewRelations: showsOverviewRelations,
                                                hasHover: hasHover) == .detail)
            }
        }
    }

    @Test
    func zoomedOutRelationsArePaintedWithOrWithoutAHover() {
        // The point of the setting: pulses stay visible at overview zoom instead of
        // waiting for the pointer to land on a table.
        #expect(GraphEdgeLayerPlan.mode(isOverview: true, isSchemaReview: false,
                                        showsOverviewRelations: true, hasHover: false) == .overviewSample)
        #expect(GraphEdgeLayerPlan.mode(isOverview: true, isSchemaReview: false,
                                        showsOverviewRelations: true, hasHover: true) == .overviewSample)
    }

    @Test
    func switchingZoomedOutRelationsOffFallsBackToHoverOnly() {
        #expect(GraphEdgeLayerPlan.mode(isOverview: true, isSchemaReview: false,
                                        showsOverviewRelations: false, hasHover: true) == .overviewHoverOnly)
        #expect(GraphEdgeLayerPlan.mode(isOverview: true, isSchemaReview: false,
                                        showsOverviewRelations: false, hasHover: false) == nil)
    }

    @Test
    func aSchemaReviewIsNeverSampledOrReducedToHover() {
        // A review's whole subject is which relations changed. Bounding it to a sample
        // could drop a changed relation, and hover-only could hide every one of them.
        for showsOverviewRelations in [true, false] {
            for hasHover in [true, false] {
                #expect(GraphEdgeLayerPlan.mode(isOverview: true, isSchemaReview: true,
                                                showsOverviewRelations: showsOverviewRelations,
                                                hasHover: hasHover) == .detail)
            }
        }
    }

    @Test
    func zoomedOutRelationsAreFainterThanCloseUpOnes() {
        #expect(GraphEdgeLayerPlan.overviewInkScale > 0)
        #expect(GraphEdgeLayerPlan.overviewInkScale < 1)
    }

    // MARK: - Sampling

    @Test
    func aGraphUnderTheBudgetKeepsEveryRelation() {
        let edges = Array(0..<400)
        #expect(GraphEdgeSampling.evenSample(edges, limit: GraphEdgeLayerPlan.overviewRelationLimit) == edges)
    }

    @Test
    func aGraphOverTheBudgetIsTrimmedToIt() {
        let edges = Array(0..<9_000)
        let sampled = GraphEdgeSampling.evenSample(edges, limit: GraphEdgeLayerPlan.overviewRelationLimit)

        #expect(sampled.count == GraphEdgeLayerPlan.overviewRelationLimit)
        #expect(Set(sampled).count == sampled.count)
    }

    @Test
    func theSampleIsSpreadAcrossTheGraphRatherThanTakenFromTheFront() {
        let edges = Array(0..<9_000)
        let sampled = GraphEdgeSampling.evenSample(edges, limit: 300)

        // A prefix would crowd every surviving line into one corner of the canvas.
        #expect(sampled.min() ?? -1 < 30)
        #expect(sampled.max() ?? 0 > 8_960)
        #expect(sampled == sampled.sorted())

        let gaps = zip(sampled, sampled.dropFirst()).map { $1 - $0 }
        #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) <= 1)
    }

    @Test
    func relationsUnderThePointerAlwaysSurviveTheSample() {
        let edges = Array(0..<9_000)
        let hovered: Set<Int> = [7, 4_242, 8_999]
        let sampled = GraphEdgeSampling.evenSample(edges, limit: 300) { hovered.contains($0) }

        #expect(sampled.count == 300)
        #expect(hovered.isSubset(of: Set(sampled)))
    }

    @Test
    func moreHoveredRelationsThanTheBudgetStillStayBounded() {
        let edges = Array(0..<9_000)
        let sampled = GraphEdgeSampling.evenSample(edges, limit: 50) { _ in true }
        #expect(sampled.count == 50)
    }

    @Test
    func theSampleIsStableSoLinesDoNotFlickerWhilePanning() {
        let edges = Array(0..<9_000)
        let first = GraphEdgeSampling.evenSample(edges, limit: 512)
        let second = GraphEdgeSampling.evenSample(edges, limit: 512)
        #expect(first == second)
    }

    @Test
    func anEmptyGraphOrZeroBudgetSamplesNothing() {
        #expect(GraphEdgeSampling.evenSample([Int](), limit: 100).isEmpty)
        #expect(GraphEdgeSampling.evenSample(Array(0..<10), limit: 0).isEmpty)
    }

    // MARK: - Pulses at overview zoom

    @Test
    func signalsStillTravelOnceTheWholeCatalogIsFitOnScreen() {
        // The reason for painting relations while zoomed out is to keep the pulses
        // readable there. A catalog compressed to one screen leaves many relations too
        // short to animate, so this pins down that a useful number still survive.
        let overview = OverviewFixture(nodeCount: 420, viewport: CGSize(width: 1_200, height: 800))
        let tracks = GraphEdgePulseField.select(from: overview.tracks)

        #expect(overview.tracks.count > GraphEdgePulseField.trackLimit)
        #expect(tracks.count == GraphEdgePulseField.trackLimit)
        #expect(tracks.allSatisfy { GraphEdgePulseField.length(of: $0) >= GraphEdgePulseField.minimumTrackLength })

        // And they are genuinely in motion, not a static field of dots.
        let firing = tracks.count { GraphEdgePulseField.pulse(on: $0, at: 4_321.5) != nil }
        #expect(firing > 10)
    }

    @Test
    func theOverviewPaintsFarFewerRelationsThanADenseCatalogHolds() {
        let edges = Array(0..<9_000)
        let painted = GraphEdgeSampling.evenSample(edges, limit: GraphEdgeLayerPlan.overviewRelationLimit)
        #expect(painted.count * 5 < edges.count)
    }
}

/// A large catalog laid out and then fit to one screen, the way the overview presents it.
private struct OverviewFixture {
    let zoom: CGFloat
    let tracks: [GraphEdgePulseTrack]

    init(nodeCount: Int, viewport: CGSize) {
        // Nodes on a loose grid with cluster-ish jitter, spanning a world far larger than
        // the viewport — the shape a settled force layout leaves behind.
        let columns = Int(Double(nodeCount).squareRoot().rounded(.up))
        let spacing: CGFloat = 220
        var centers: [CGPoint] = []
        for index in 0..<nodeCount {
            let column = CGFloat(index % columns)
            let row = CGFloat(index / columns)
            let jitter = CGFloat((index &* 2_654_435_761) % 97) - 48
            centers.append(CGPoint(x: column * spacing + jitter, y: row * spacing + jitter * 0.7))
        }

        let bounds = centers.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 1, height: 1)) }
        let transform = GraphViewportTransform.fit(contentBounds: bounds, in: viewport,
                                                  padding: 120, minZoom: 0.005, maxZoom: 1.15)
        self.zoom = transform.zoom

        // Mostly near neighbours, with the long-haul relations a real schema also has.
        var tracks: [GraphEdgePulseTrack] = []
        for index in 0..<nodeCount {
            for hop in [1, columns, (index &* 7) % nodeCount] where hop > 0 && index + hop < nodeCount {
                let start = transform.point(for: centers[index], in: viewport)
                let end = transform.point(for: centers[index + hop], in: viewport)
                let delta = end.x - start.x
                let offset = max(32, abs(delta) * 0.34)
                tracks.append(GraphEdgePulseTrack(
                    edgeID: "t\(index).fk->t\(index + hop).id",
                    start: start,
                    control1: CGPoint(x: start.x + (delta >= 0 ? offset : -offset), y: start.y),
                    control2: CGPoint(x: end.x - (delta >= 0 ? offset : -offset), y: end.y),
                    end: end,
                    isHighlighted: false
                ))
            }
        }
        self.tracks = tracks
    }
}
