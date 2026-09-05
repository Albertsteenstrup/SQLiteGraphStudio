import Foundation
import Testing
@testable import StudioCore

@MainActor
struct LargeGraphLayoutTests {
    @Test
    func authoredGroupsHaveSeparateRegionsDespiteCrossGroupEdges() {
        let fixture = makeLargeLayoutFixture(nodeCount: 585, groupSize: 65)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        layout.stabilize(graph: fixture.graph, presentation: .compact,
                         descriptorLookup: nil, nodeSizeLookup: { _ in fixture.compactSize })

        let regions = groupBounds(fixture: fixture, layout: layout)
        #expect(regions.count == 9)
        #expect(overlappingPairCount(Array(regions.values)) == 0)
        #expect(layout.allPositions(for: fixture.graph).count == 585)
        #expect(layout.allPositions(for: fixture.graph).values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test
    func expandingLargeGraphSeparatesRealCardSizesWithZeroPhysicsIterations() {
        let fixture = makeLargeLayoutFixture(nodeCount: 585, groupSize: 65)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        layout.stabilize(graph: fixture.graph, presentation: .compact,
                         descriptorLookup: nil, nodeSizeLookup: { _ in fixture.compactSize })
        layout.relayoutPreservingCurrentPositions(for: fixture.graph, presentation: .allCards,
                                                 descriptorLookup: nil)
        layout.stabilize(graph: fixture.graph, presentation: .allCards,
                         descriptorLookup: nil, nodeSizeLookup: largeCardSize, maxIterations: 0)

        let frames = fixture.graph.nodes.map { node in
            layoutFrame(center: layout.position(for: node.id), size: largeCardSize(node.id))
        }
        #expect(overlappingPairCount(frames) == 0)
        #expect(!layout.isAnimating)
        #expect(layout.hasSettledLayout)
    }

    @Test
    func largeLayoutIsIndependentOfNodeAndEdgeInputOrder() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        let reversedGraph = SchemaGraph(nodes: Array(fixture.graph.nodes.reversed()), edges: Array(fixture.graph.edges.reversed()))
        let first = GraphLayoutModel()
        let second = GraphLayoutModel()
        for (layout, graph) in [(first, fixture.graph), (second, reversedGraph)] {
            layout.setClusterHints(fixture.hints)
            layout.reset(for: graph)
            layout.stabilize(graph: graph, presentation: .compact,
                             descriptorLookup: nil, nodeSizeLookup: { _ in fixture.compactSize })
        }
        #expect(first.allPositions(for: fixture.graph) == second.allPositions(for: fixture.graph))
    }

    @Test
    func largeStabilizationRespectsPinnedCardsAndMovesTheirOverlappingNeighbors() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        let pinnedID = fixture.graph.nodes[0].id
        let neighborID = fixture.graph.nodes[1].id
        let fixedPoint = layout.position(for: neighborID)
        layout.pin(nodeID: pinnedID, at: fixedPoint)
        layout.stabilize(graph: fixture.graph, presentation: .allCards,
                         descriptorLookup: nil, nodeSizeLookup: largeCardSize, maxIterations: 0)

        #expect(layout.position(for: pinnedID) == fixedPoint)
        #expect(layout.snapshot(for: fixture.graph).pinnedPositions[pinnedID] == fixedPoint)
        let frames = fixture.graph.nodes.map { node in
            layoutFrame(center: layout.position(for: node.id), size: largeCardSize(node.id))
        }
        #expect(overlappingPairCount(frames) == 0)
    }

    @Test
    func restoringOldOverviewGridRegeneratesGeometryAndKeepsSavedPins() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        var oldPositions: [String: CGPoint] = [:]
        for (index, node) in fixture.graph.nodes.enumerated() {
            oldPositions[node.id] = CGPoint(x: CGFloat((index % 10) * 410), y: CGFloat((index / 10) * 74))
        }
        let pinnedID = fixture.graph.nodes[0].id
        let pin = CGPoint(x: -345, y: 980)
        oldPositions[pinnedID] = pin
        let snapshot = GraphLayoutSnapshot(positions: oldPositions, pinnedPositions: [pinnedID: pin])
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.restore(snapshot, for: fixture.graph, presentation: .compact, descriptorLookup: nil)

        #expect(layout.position(for: pinnedID) == pin)
        #expect(layout.snapshot(for: fixture.graph).pinnedPositions[pinnedID] == pin)
        #expect(layout.allPositions(for: fixture.graph) != oldPositions)
        #expect(layout.hasRestoredSnapshot)
        #expect(layout.hasSettledLayout)
        #expect(!layout.isAnimating)
    }

    @Test(arguments: [585, 1_000, 2_000], [GraphPresentationMode.compact, .allCards])
    func giantAuthoredGroupPlacesEveryTableWithoutCollisions(nodeCount: Int, presentation: GraphPresentationMode) {
        let fixture = makeLargeLayoutFixture(nodeCount: nodeCount, groupSize: nodeCount)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        let sizeForNode: (String) -> CGSize = { id in
            presentation == .compact ? fixture.compactSize : largeCardSize(id)
        }
        let started = ContinuousClock.now
        layout.reset(for: fixture.graph, presentation: presentation, descriptorLookup: nil)
        let seeded = ContinuousClock.now
        layout.stabilize(graph: fixture.graph, presentation: presentation,
                         descriptorLookup: nil, nodeSizeLookup: sizeForNode)
        let elapsed = started.duration(to: .now)

        let points = layout.allPositions(for: fixture.graph)
        #expect(points.count == nodeCount)
        #expect(points.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let frames = fixture.graph.nodes.map { node in
            layoutFrame(center: layout.position(for: node.id), size: sizeForNode(node.id))
        }
        #expect(overlappingPairCount(frames) == 0)
        let metrics = layout.largeGraphLayoutMetrics
        #expect(metrics != nil)
        #expect(metrics!.largestPartition <= LargeGraphLayout.maximumLocalNodeCount)
        #expect(metrics!.partitionCount == (nodeCount + LargeGraphLayout.maximumLocalNodeCount - 1) / LargeGraphLayout.maximumLocalNodeCount)
        #expect(metrics!.physicsSteps > 0)
        #expect(metrics!.physicsSteps <= metrics!.partitionCount * LargeGraphLayout.maximumPhysicsIterations)
        #expect(metrics!.pairEvaluations <= nodeCount * (LargeGraphLayout.maximumLocalNodeCount - 1) / 2 * LargeGraphLayout.maximumPhysicsIterations)
        #expect(metrics!.edgePathEvaluations <= fixture.graph.edges.count * (LargeGraphLayout.maximumLocalNodeCount - 2) * LargeGraphLayout.maximumPhysicsIterations)
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        print("Large graph: \(nodeCount) tables, \(presentation) layout \(elapsed), seed \(started.duration(to: seeded)), bounds \(bounds.width) × \(bounds.height)")
    }

    @Test
    func publicStepKeepsTheLargeGraphOnTheBoundedPath() {
        let fixture = makeLargeLayoutFixture(nodeCount: 2_000, groupSize: 2_000)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        layout.step(graph: fixture.graph)

        let metrics = layout.largeGraphLayoutMetrics
        #expect(metrics != nil)
        #expect(metrics!.largestPartition <= LargeGraphLayout.maximumLocalNodeCount)
        #expect(metrics!.physicsSteps <= metrics!.partitionCount)
        #expect(metrics!.pairEvaluations <= 2_000 * (LargeGraphLayout.maximumLocalNodeCount - 1) / 2)
        #expect(!layout.isAnimating)
        #expect(layout.hasSettledLayout)
        #expect(layout.allPositions(for: fixture.graph).values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test
    func allCardsStepCachesMetadataLookupsPerTableForDenseEdges() {
        let fixture = makeLargeLayoutFixture(nodeCount: 585, groupSize: 585)
        let nodes = fixture.graph.nodes
        let edges = nodes.indices.flatMap { index in
            (1...8).map { offset in
                GraphEdge(id: "dense_\(index)_\(offset)", sourceID: nodes[index].id,
                          targetID: nodes[(index + offset) % nodes.count].id,
                          sourceColumn: "parent_id", targetColumn: "id")
            }
        }
        let graph = SchemaGraph(nodes: nodes, edges: edges)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        var descriptorLookups = 0
        var sizeLookups = 0
        let descriptorLookup: (String) -> EditableTableDescriptor? = { _ in
            descriptorLookups += 1
            return nil
        }
        layout.reset(for: graph, presentation: .allCards, descriptorLookup: descriptorLookup)
        layout.step(graph: graph, presentation: .allCards, descriptorLookup: descriptorLookup,
                    nodeSizeLookup: { id in sizeLookups += 1; return largeCardSize(id) })

        #expect(descriptorLookups == nodes.count * 2)
        #expect(sizeLookups == nodes.count)
        #expect(layout.largeGraphLayoutMetrics!.largestPartition <= LargeGraphLayout.maximumLocalNodeCount)
        let frames = nodes.map { layoutFrame(center: layout.position(for: $0.id), size: largeCardSize($0.id)) }
        #expect(overlappingPairCount(frames) == 0)
    }

    @Test
    func restoringCurrentLargeLayoutKeepsEverySavedPosition() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        let original = GraphLayoutModel()
        original.setClusterHints(fixture.hints)
        original.reset(for: fixture.graph)
        original.stabilize(graph: fixture.graph, presentation: .compact,
                           descriptorLookup: nil, nodeSizeLookup: nil)
        let id = fixture.graph.nodes[0].id
        original.pin(nodeID: id, at: original.position(for: id))
        let snapshot = original.snapshot(for: fixture.graph)
        let restored = GraphLayoutModel()
        restored.setClusterHints(fixture.hints)
        restored.restore(snapshot, for: fixture.graph, presentation: .compact, descriptorLookup: nil)

        #expect(restored.snapshot(for: fixture.graph) == snapshot)
    }

    @Test
    func presentationTransitionKeepsLargeGraphPins() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        let id = fixture.graph.nodes[0].id
        let pin = CGPoint(x: -4_000, y: -2_000)
        layout.pin(nodeID: id, at: pin)
        layout.relayoutPreservingCurrentPositions(for: fixture.graph, presentation: .allCards,
                                                 descriptorLookup: nil)
        layout.stabilize(graph: fixture.graph, presentation: .allCards,
                         descriptorLookup: nil, nodeSizeLookup: largeCardSize, maxIterations: 0)

        #expect(layout.position(for: id) == pin)
        #expect(layout.snapshot(for: fixture.graph).pinnedPositions[id] == pin)
    }

    @Test
    func conflictingSavedPinsRemainFixedWithBoundedObstacleWork() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        let original = GraphLayoutModel()
        original.setClusterHints(fixture.hints)
        original.reset(for: fixture.graph)
        let pins = Dictionary(uniqueKeysWithValues: fixture.graph.nodes.prefix(130).map { ($0.id, CGPoint.zero) })
        let snapshot = GraphLayoutSnapshot(positions: original.allPositions(for: fixture.graph), pinnedPositions: pins)
        let restored = GraphLayoutModel()
        restored.setClusterHints(fixture.hints)
        restored.restore(snapshot, for: fixture.graph, presentation: .compact, descriptorLookup: nil)

        #expect(restored.snapshot(for: fixture.graph).pinnedPositions == pins)
        #expect(pins.keys.allSatisfy { restored.position(for: $0) == .zero })
        #expect(restored.largeGraphLayoutMetrics!.obstacleChecks <= fixture.graph.nodes.count * 8 * LargeGraphLayout.maximumLocalNodeCount)
        for node in fixture.graph.nodes where pins[node.id] == nil {
            let size = GraphCardLayout.nodeSize(title: node.title, descriptor: nil, style: .collapsed)
            #expect(!layoutFrame(center: restored.position(for: node.id), size: size).intersects(layoutFrame(center: .zero, size: size)))
        }
    }

    @Test
    func connectedTablesStayCloserThanUnrelatedTablesAcrossTheOverview() {
        let fixture = makeLargeLayoutFixture(nodeCount: 585, groupSize: 65)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        layout.stabilize(graph: fixture.graph, presentation: .compact,
                         descriptorLookup: nil, nodeSizeLookup: nil)
        func distance(_ first: String, _ second: String) -> CGFloat {
            let lhs = layout.position(for: first)
            let rhs = layout.position(for: second)
            return hypot(lhs.x - rhs.x, lhs.y - rhs.y)
        }
        let linkedMean = fixture.graph.edges.reduce(CGFloat.zero) {
            $0 + distance($1.sourceID, $1.targetID)
        } / CGFloat(fixture.graph.edges.count)
        let unrelatedMean = fixture.graph.nodes.indices.reduce(CGFloat.zero) { total, index in
            total + distance(fixture.graph.nodes[index].id, fixture.graph.nodes[(index + 292) % 585].id)
        } / 585

        #expect(linkedMean < unrelatedMean * 0.75)
        print("Large graph linked/unrelated mean distance ratio: \(linkedMean / unrelatedMean)")
    }

    @Test
    func steppingAfterDirectPresentationStabilizationKeepsTheDragPin() {
        let fixture = makeLargeLayoutFixture(nodeCount: 195, groupSize: 39)
        let layout = GraphLayoutModel()
        layout.setClusterHints(fixture.hints)
        layout.reset(for: fixture.graph)
        layout.stabilize(graph: fixture.graph, presentation: .allCards,
                         descriptorLookup: nil, nodeSizeLookup: largeCardSize, maxIterations: 0)
        let id = fixture.graph.nodes[0].id
        let pin = CGPoint(x: -4_000, y: -2_000)
        layout.pin(nodeID: id, at: pin, shouldAnimate: true)
        layout.step(graph: fixture.graph, presentation: .allCards,
                    descriptorLookup: nil, nodeSizeLookup: largeCardSize)

        #expect(layout.position(for: id) == pin)
        #expect(layout.snapshot(for: fixture.graph).pinnedPositions[id] == pin)
    }
}

private struct LargeLayoutFixture {
    let graph: SchemaGraph
    let hints: [String: String]
    let compactSize = CGSize(width: 300, height: 46)
}

private func makeLargeLayoutFixture(nodeCount: Int, groupSize: Int) -> LargeLayoutFixture {
    let nodes = (0..<nodeCount).map { index in
        let id = String(format: "table_%04d", index)
        return GraphNode(id: id, title: id, isEditable: false)
    }
    var edges: [GraphEdge] = []
    var hints: [String: String] = [:]
    for (index, node) in nodes.enumerated() {
        hints[node.id] = String(format: "Group %03d", index / groupSize)
        if index % groupSize != 0 {
            edges.append(GraphEdge(id: "chain_\(index)", sourceID: node.id,
                                   targetID: nodes[index - 1].id, sourceColumn: "parent_id", targetColumn: "id"))
        }
        if index + groupSize < nodeCount {
            edges.append(GraphEdge(id: "cross_\(index)", sourceID: node.id,
                                   targetID: nodes[index + groupSize].id, sourceColumn: "group_id", targetColumn: "id"))
        }
    }
    return LargeLayoutFixture(graph: SchemaGraph(nodes: nodes, edges: edges), hints: hints)
}

private func largeCardSize(_ id: String) -> CGSize {
    let index = Int(id.suffix(4)) ?? 0
    return CGSize(width: CGFloat(308 + (index % 3) * 28), height: CGFloat(140 + (index % 5) * 48))
}

private func layoutFrame(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
           width: size.width, height: size.height)
}

@MainActor
private func groupBounds(fixture: LargeLayoutFixture, layout: GraphLayoutModel) -> [String: CGRect] {
    var bounds: [String: CGRect] = [:]
    for node in fixture.graph.nodes {
        let group = fixture.hints[node.id]!
        let frame = layoutFrame(center: layout.position(for: node.id), size: fixture.compactSize)
        bounds[group] = (bounds[group] ?? .null).union(frame)
    }
    return bounds
}

private func overlappingPairCount(_ frames: [CGRect]) -> Int {
    var overlaps = 0
    for left in frames.indices {
        for right in frames.indices where right > left {
            if frames[left].intersects(frames[right]) { overlaps += 1 }
        }
    }
    return overlaps
}
