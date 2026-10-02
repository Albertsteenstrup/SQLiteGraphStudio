import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

@MainActor
struct GraphNodeResizeLayoutTests {
    @Test func neighbourChainsStayLocalInsteadOfBouncingToTheOverflowShelf() {
        let points = ["left": CGPoint.zero, "right": CGPoint(x: 150, y: 0),
                      "small": CGPoint(x: 75, y: 0), "distant": CGPoint(x: 5_000, y: 0)]
        let sizes = points.mapValues { _ in CGSize(width: 100, height: 100) }
            .merging(["small": CGSize(width: 20, height: 20)]) { _, smaller in smaller }
        let result = LargeGraphLayout.separatingNodes(points, sizes: sizes)
        #expect(result["small"] == CGPoint(x: 235, y: 0))
        #expect(result["left"] == points["left"])
        #expect(result["right"] == points["right"])
        #expect(result["distant"] == points["distant"])
    }

    @Test func growthPushesEachSideByItsActualClearanceWithoutMovingDistantNodes() {
        let points = ["hub": CGPoint.zero, "left": CGPoint(x: -130, y: 0), "right": CGPoint(x: 130, y: 0),
                      "above": CGPoint(x: 0, y: -60), "below": CGPoint(x: 0, y: 60), "distant": CGPoint(x: 2_000, y: 0)]
        let sizes = points.mapValues { _ in CGSize(width: 100, height: 40) }
            .merging(["hub": CGSize(width: 400, height: 120)]) { _, grown in grown }
        let graph = SchemaGraph(nodes: points.keys.sorted().map { GraphNode(id: $0, title: $0, isEditable: true) }, edges: [])
        let layout = GraphLayoutModel()
        layout.restore(.init(positions: points, pinnedPositions: [:]), for: graph,
                       presentation: .compact, descriptorLookup: nil)
        #expect(layout.resizeNodes(for: graph, sizes: sizes))
        #expect(layout.position(for: "hub") == .zero)
        #expect(layout.position(for: "distant") == points["distant"])
        #expect(layout.position(for: "left") == CGPoint(x: -275, y: 0))
        #expect(layout.position(for: "right") == CGPoint(x: 275, y: 0))
        #expect(layout.position(for: "above") == CGPoint(x: 0, y: -105))
        #expect(layout.position(for: "below") == CGPoint(x: 0, y: 105))
        #expect(!layout.resizeNodes(for: graph, sizes: sizes))
    }

    @Test(arguments: [30, 585])
    func denseGrowingLayoutsHaveNoOverlapsAndKeepDeterministicPositions(count: Int) {
        let ids = (0..<count).map { String(format: "table_%04d", $0) }
        let points = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGPoint(x: (index % 12) * 250, y: (index / 12) * 74))
        })
        let sizes = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, index.isMultiple(of: 3) ? CGSize(width: 680, height: 140) : CGSize(width: 226, height: 46))
        })
        let result = LargeGraphLayout.separatingNodes(points, sizes: sizes)
        let reversed = LargeGraphLayout.separatingNodes(Dictionary(uniqueKeysWithValues: ids.reversed().map { ($0, points[$0]!) }), sizes: sizes)
        #expect(result == reversed)
        #expect(result.count == count)
        let frames = ids.map { id in
            let point = result[id]!, size = sizes[id]!
            return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: size.width, height: size.height).insetBy(dx: -11, dy: -11)
        }
        for i in frames.indices {
            for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
        }
    }

    @Test func growingPinnedNeighboursRetainTheirPinStateAndMakeRoom() {
        let graph = SchemaGraph(nodes: [GraphNode(id: "a", title: "a", isEditable: true),
                                        GraphNode(id: "b", title: "b", isEditable: true)], edges: [])
        let pins = ["a": CGPoint.zero, "b": CGPoint(x: 250, y: 0)]
        let layout = GraphLayoutModel()
        layout.restore(.init(positions: pins, pinnedPositions: pins), for: graph,
                       presentation: .compact, descriptorLookup: nil)
        layout.resizeNodes(for: graph, sizes: ["a": CGSize(width: 600, height: 100), "b": CGSize(width: 200, height: 46)])
        #expect(layout.position(for: "a") == .zero)
        #expect(layout.position(for: "b") == CGPoint(x: 425, y: 0))
        let snapshot = layout.snapshot(for: graph)
        #expect(Set(snapshot.pinnedPositions.keys) == ["a", "b"])
        #expect(snapshot.pinnedPositions == snapshot.positions)
    }
}
