import CoreGraphics
import Testing
@testable import StudioCore

struct GraphSpotlightTests {
    @Test(arguments: [21, 50, 60, 100, 129]) @MainActor
    func denseSummaryColumnsSurviveCollisionResolution(count: Int) {
        let zoom: CGFloat = 0.76
        let rootSize = CGSize(width: 440, height: 236)
        let ids = (0..<count).map { "related_\($0)" }
        let plan = GraphFocusSummaryLayout.plan(rootSize: CGSize(width: 336, height: 236 * zoom),
            relatedIDs: ids, viewport: CGSize(width: 840, height: 552))
        var positions = plan.offsets.mapValues { CGPoint(x: $0.x / zoom, y: $0.y / zoom) }
        positions["root"] = .zero
        var sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGSize(width: 560, height: 46)) })
        sizes["root"] = rootSize
        let placed = GraphSpotlightLayout.focusedPositions(positions, cardSizes: sizes, rootID: "root",
            summarySizes: Dictionary(uniqueKeysWithValues: ids.map { ($0, plan.summarySize) }),
            zoom: zoom, viewportWidth: 840, sizing: .uniform, manuallyPlacedNodes: [:])
        for id in ids {
            #expect(abs(placed[id]!.x - positions[id]!.x) < 0.00001)
            #expect(abs(placed[id]!.y - positions[id]!.y) < 0.00001)
        }
    }

    @Test @MainActor
    func focusedCardsStayFixedWhileTheCatalogMovesAndManualDropsSurviveZoom() {
        let positions: [String: CGPoint] = ["root": .zero, "related": .init(x: -600, y: 0),
                                            "background": .zero]
        let sizes: [String: CGSize] = ["root": .init(width: 440, height: 236),
                                      "related": .init(width: 280, height: 80),
                                      "background": .init(width: 560, height: 200)]
        let dropped = CGPoint(x: -4_000, y: 700)
        for zoom in [CGFloat(0.2), 0.76, 1] {
            let placed = GraphSpotlightLayout.focusedPositions(positions, cardSizes: sizes, rootID: "root",
                summarySizes: ["related": CGSize(width: 190, height: 38)], zoom: zoom, viewportWidth: 840,
                sizing: .uniform, manuallyPlacedNodes: ["related": dropped])
            #expect(placed["root"] == .zero)
            #expect(placed["related"] == dropped)
            #expect(placed["background"] != .zero)
        }
    }

    @Test @MainActor
    func draggingAFocusedNeighbourSurvivesReflowAndZoom() {
        let original: [String: CGPoint] = ["hub": .zero, "neighbour": .init(x: 600, y: 0)]
        let sizes: [String: CGSize] = ["hub": .init(width: 440, height: 236),
                                      "neighbour": .init(width: 200, height: 46)]
        let dropped = CGPoint(x: -4_000, y: 700)
        for zoom: CGFloat in [0.2, 0.5, 1] {
            // Each reflow starts with a fresh generated arrangement, as it does
            // after native key-focus dragging finishes and the viewport changes.
            let generated = GraphFocusRingLayout.graphPositions(hubCenter: .zero, hubSize: sizes["hub"]!,
                items: [.init(id: "neighbour", size: sizes["neighbour"]!)])
            let reflowed = GraphSpotlightLayout.positions(original.merging(generated) { _, ring in ring },
                cardSizes: sizes, expandedIDs: ["hub"], readableRootID: "hub", zoom: zoom,
                manuallyPlacedNodes: ["neighbour": dropped])
            #expect(reflowed["neighbour"] == dropped)
            #expect(reflowed["hub"] == .zero)
        }
        let nextFocus = GraphSpotlightLayout.positions(original, cardSizes: sizes,
            expandedIDs: ["hub"], readableRootID: "hub", zoom: 1)
        #expect(nextFocus["neighbour"] == original["neighbour"], "A new focus can discard temporary drag overrides")
    }

    @Test(arguments: [CGFloat(0.05), 0.2, 0.8]) @MainActor
    func severalEnlargedTablesClearEachOtherAndTheirNeighbours(zoom: CGFloat) {
        let positions: [String: CGPoint] = ["a": .zero, "b": .init(x: 330, y: 40),
                                            "context": .init(x: 160, y: 80),
                                            "distant": .init(x: 40_000, y: 0)]
        let sizes: [String: CGSize] = ["a": .init(width: 440, height: 236),
                                      "b": .init(width: 440, height: 168),
                                      "context": .init(width: 200, height: 46),
                                      "distant": .init(width: 200, height: 46)]
        let pushed = GraphSpotlightLayout.positions(positions, cardSizes: sizes,
            expandedIDs: ["a", "b"], readableRootID: nil, zoom: zoom, enlargedIDs: ["a", "b"])
        let enlargedScale: CGFloat = zoom <= 0.2 ? 0.7 * sqrt(zoom / 0.2) : zoom
        let frames = Dictionary(uniqueKeysWithValues: sizes.map { id, size in
            let scale = id == "a" || id == "b" ? enlargedScale : zoom
            let center = pushed[id]!
            return (id, CGRect(x: center.x * zoom - size.width * scale / 2,
                               y: center.y * zoom - size.height * scale / 2,
                               width: size.width * scale, height: size.height * scale))
        })
        for id in ["a", "b", "context"] {
            for other in ["a", "b", "context"] where id != other {
                #expect(!frames[id]!.intersects(frames[other]!))
                if id == "a" || id == "b" {
                    #expect(!frames[id]!.insetBy(dx: -36, dy: -36)
                        .intersects(frames[other]!.insetBy(dx: -36, dy: -36)),
                        "Enlarged tables need a 72-point screen corridor for endpoint labels")
                }
            }
        }
        #expect(pushed["distant"] == positions["distant"])
        #expect(Set(pushed.keys) == Set(positions.keys))
    }

    @Test func subjectsStayClearAndContextRemainsVisible() {
        let focus = GraphSpotlight(subjects: ["records", "revisions"], related: ["users"], pointed: nil)
        #expect(focus.tableOpacity("records") == 1)
        #expect(focus.tableOpacity("revisions") == 1)
        #expect(focus.tableOpacity("users") > focus.tableOpacity("unrelated"))
        #expect(focus.tableOpacity("users") < 1)
        #expect(focus.tableOpacity("unrelated") > 0)
        #expect(focus.edgeOpacity(source: "records", target: "revisions") == 1)
        #expect(focus.edgeOpacity(source: "records", target: "users")
                > focus.edgeOpacity(source: "orders", target: "products"))
        #expect(focus.edgeOpacity(source: "orders", target: "products") > 0)
    }

    @Test func pointingAtContextDoesNotReplaceTheAuthoredSubject() {
        let focus = GraphSpotlight(subjects: ["records"], related: ["users"], pointed: "orders")
        #expect(focus.tableOpacity("records") == 1)
        #expect(focus.tableOpacity("orders") == 1)
        #expect(focus.tableOpacity("products") < focus.tableOpacity("users"))
        let overview = GraphSpotlight(subjects: [], related: [], pointed: nil)
        #expect(overview.tableOpacity("records") == 1)
        #expect(overview.edgeOpacity(source: "orders", target: "products") == 1)
    }

    @Test(arguments: [CGFloat(0.05), 0.2, 0.5, 1, 2.4]) @MainActor
    func expandingReservesTheDisplayedReadableCardAndKeepsItsLocation(zoom: CGFloat) {
        let original: [String: CGPoint] = ["hub": .zero, "left": .init(x: -250, y: 0),
                                           "right": .init(x: 250, y: 0),
                                           "above": .init(x: 0, y: -100), "below": .init(x: 0, y: 100),
                                           "distant": .init(x: 20_000, y: 0)]
        let sizes: [String: CGSize] = ["hub": .init(width: 440, height: 236),
                                      "left": .init(width: 200, height: 46),
                                      "right": .init(width: 200, height: 46),
                                      "above": .init(width: 200, height: 46),
                                      "below": .init(width: 200, height: 46),
                                      "distant": .init(width: 200, height: 46)]
        let positions = GraphSpotlightLayout.positions(original, cardSizes: sizes,
            expandedIDs: ["hub"], readableRootID: "hub", zoom: zoom)
        #expect(positions["hub"] == .zero)
        #expect(positions["distant"] == original["distant"])
        #expect(positions["left"]!.x < original["left"]!.x)
        #expect(positions["right"]!.x > original["right"]!.x)
        let rootScale = max(zoom, 0.9)
        let hub = CGRect(x: -220 * rootScale, y: -118 * rootScale,
                         width: 440 * rootScale, height: 236 * rootScale)
        var cardFrames = ["hub": hub]
        for id in ["left", "right", "above", "below"] {
            let center = positions[id]!
            let frame = CGRect(x: (center.x - 100) * zoom, y: (center.y - 23) * zoom,
                               width: 200 * zoom, height: 46 * zoom)
            #expect(!frame.intersects(hub))
            #expect(!frame.insetBy(dx: -36, dy: -36)
                .intersects(hub.insetBy(dx: -36, dy: -36)),
                "The readable table must retain label space when zooming out")
            cardFrames[id] = frame
        }
        let cards = cardFrames.mapValues { frame in
            GraphCardGeometry(tableID: "fixture", frame: frame, role: .collapsedNode, descriptor: nil)
        }
        let anchors = GraphAnchorMap(nodeCards: cards)
        for id in ["left", "right", "above", "below"] {
            let edge = GraphEdge(id: id, sourceID: "hub", targetID: id,
                                 sourceColumn: "id", targetColumn: "id")
            guard let endpoints = anchors.edgeAnchors(for: edge) else {
                Issue.record("Both visible endpoint cards must expose relation anchors")
                continue
            }
            let curve = GraphEdgeRouting.curve(anchors: endpoints, sourceFrame: hub,
                                              targetFrame: cardFrames[id])
            var occupied: [CGRect] = []
            #expect(GraphCardinalityLabelPlacement.position(on: curve, atSource: true,
                cardFrames: Array(cardFrames.values), occupied: &occupied) != nil)
            #expect(GraphCardinalityLabelPlacement.position(on: curve, atSource: false,
                cardFrames: Array(cardFrames.values), occupied: &occupied) != nil,
                "The reserved corridor must fit cardinality marks at both ends")
        }
        #expect(Set(positions.keys) == Set(original.keys))
        #expect(original["left"] == CGPoint(x: -250, y: 0), "Spotlighting is a temporary layout")
    }
}
