import CoreGraphics
import Testing
@testable import StudioCore

struct GraphSpotlightTests {
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

    @Test(arguments: [CGFloat(0.05), 0.5, 1]) @MainActor
    func expandingReservesTheDisplayedReadableCardAndKeepsItsLocation(zoom: CGFloat) {
        let original: [String: CGPoint] = ["hub": .zero, "left": .init(x: -250, y: 0),
                                           "right": .init(x: 250, y: 0), "distant": .init(x: 20_000, y: 0)]
        let sizes: [String: CGSize] = ["hub": .init(width: 440, height: 236),
                                      "left": .init(width: 200, height: 46),
                                      "right": .init(width: 200, height: 46),
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
        for id in ["left", "right"] {
            let center = positions[id]!
            let frame = CGRect(x: (center.x - 100) * zoom, y: (center.y - 23) * zoom,
                               width: 200 * zoom, height: 46 * zoom)
            #expect(!frame.intersects(hub))
        }
        #expect(Set(positions.keys) == Set(original.keys))
        #expect(original["left"] == CGPoint(x: -250, y: 0), "Spotlighting is a temporary layout")
    }
}
