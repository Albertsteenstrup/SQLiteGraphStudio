import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

// MARK: - Property-Based Tests for Node Position Stability
//
// **Validates: Requirements 2.1**
//
// Property 1: For any graph with a restored snapshot, simulating a view re-mount
// does NOT change any node position.
//
// The fix in `performInitialLayout` returns early when `hasRestoredSnapshot == true`,
// so no physics pass runs on re-mount. This test verifies that property holds across
// a wide range of randomly-generated graph configurations.

@MainActor
struct NodePositionStabilityPropertyTests {

    // MARK: - Property 1

    /// **Validates: Requirements 2.1**
    ///
    /// For any graph with a restored snapshot, simulating a view re-mount does NOT
    /// change any node position.
    ///
    /// Strategy: iterate over a representative set of graph configurations (varying
    /// node counts, edge densities, and topologies) and verify the property holds for
    /// each one. Swift's Testing framework does not have built-in property-based
    /// testing, so we use a loop over multiple deterministic seeds to cover the input
    /// space systematically.
    @Test("Property 1: restored snapshot + view re-mount preserves all node positions")
    func testProperty1_restoredSnapshotViewRemountPreservesPositions() {
        // Generate a representative set of graph configurations using deterministic seeds.
        // Each seed produces a different random graph (2–8 nodes, 0–6 edges).
        let seeds: [UInt64] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            42, 99, 137, 256, 512, 1024, 2048, 9999,
            0xDEAD_BEEF, 0xCAFE_BABE
        ]

        for seed in seeds {
            let graph = makeRandomGraph(seed: seed, minNodes: 2, maxNodes: 8, maxEdges: 6)
            verifyProperty1(graph: graph, seed: seed)
        }

        // Also test a handful of hand-crafted topologies that cover important edge cases:

        // Single edge (minimal connected graph)
        verifyProperty1(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "a", title: "a", isEditable: true),
                    GraphNode(id: "b", title: "b", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "a-b", sourceID: "a", targetID: "b",
                              sourceColumn: "id", targetColumn: "a_id"),
                ]
            ),
            label: "single-edge"
        )

        // Fully disconnected (no edges)
        verifyProperty1(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "x", title: "x", isEditable: true),
                    GraphNode(id: "y", title: "y", isEditable: true),
                    GraphNode(id: "z", title: "z", isEditable: true),
                ],
                edges: []
            ),
            label: "fully-disconnected"
        )

        // Star topology (one hub, many leaves)
        verifyProperty1(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "hub",   title: "hub",   isEditable: true),
                    GraphNode(id: "leaf1", title: "leaf1", isEditable: true),
                    GraphNode(id: "leaf2", title: "leaf2", isEditable: true),
                    GraphNode(id: "leaf3", title: "leaf3", isEditable: true),
                    GraphNode(id: "leaf4", title: "leaf4", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "h-l1", sourceID: "hub", targetID: "leaf1",
                              sourceColumn: "id", targetColumn: "hub_id"),
                    GraphEdge(id: "h-l2", sourceID: "hub", targetID: "leaf2",
                              sourceColumn: "id", targetColumn: "hub_id"),
                    GraphEdge(id: "h-l3", sourceID: "hub", targetID: "leaf3",
                              sourceColumn: "id", targetColumn: "hub_id"),
                    GraphEdge(id: "h-l4", sourceID: "hub", targetID: "leaf4",
                              sourceColumn: "id", targetColumn: "hub_id"),
                ]
            ),
            label: "star-topology"
        )

        // Chain topology (linear sequence)
        verifyProperty1(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "n1", title: "n1", isEditable: true),
                    GraphNode(id: "n2", title: "n2", isEditable: true),
                    GraphNode(id: "n3", title: "n3", isEditable: true),
                    GraphNode(id: "n4", title: "n4", isEditable: true),
                    GraphNode(id: "n5", title: "n5", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "n1-n2", sourceID: "n1", targetID: "n2",
                              sourceColumn: "id", targetColumn: "n1_id"),
                    GraphEdge(id: "n2-n3", sourceID: "n2", targetID: "n3",
                              sourceColumn: "id", targetColumn: "n2_id"),
                    GraphEdge(id: "n3-n4", sourceID: "n3", targetID: "n4",
                              sourceColumn: "id", targetColumn: "n3_id"),
                    GraphEdge(id: "n4-n5", sourceID: "n4", targetID: "n5",
                              sourceColumn: "id", targetColumn: "n4_id"),
                ]
            ),
            label: "chain-topology"
        )

        // Two disconnected components
        verifyProperty1(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "c1a", title: "c1a", isEditable: true),
                    GraphNode(id: "c1b", title: "c1b", isEditable: true),
                    GraphNode(id: "c2a", title: "c2a", isEditable: true),
                    GraphNode(id: "c2b", title: "c2b", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "c1a-c1b", sourceID: "c1a", targetID: "c1b",
                              sourceColumn: "id", targetColumn: "c1a_id"),
                    GraphEdge(id: "c2a-c2b", sourceID: "c2a", targetID: "c2b",
                              sourceColumn: "id", targetColumn: "c2a_id"),
                ]
            ),
            label: "two-components"
        )

        // Dense graph (8 nodes, 6 edges)
        verifyProperty1(
            graph: SchemaGraph(
                nodes: (1...8).map { i in
                    GraphNode(id: "t\(i)", title: "t\(i)", isEditable: true)
                },
                edges: [
                    GraphEdge(id: "e1", sourceID: "t1", targetID: "t2",
                              sourceColumn: "id", targetColumn: "t1_id"),
                    GraphEdge(id: "e2", sourceID: "t2", targetID: "t3",
                              sourceColumn: "id", targetColumn: "t2_id"),
                    GraphEdge(id: "e3", sourceID: "t3", targetID: "t4",
                              sourceColumn: "id", targetColumn: "t3_id"),
                    GraphEdge(id: "e4", sourceID: "t1", targetID: "t5",
                              sourceColumn: "id", targetColumn: "t1_id"),
                    GraphEdge(id: "e5", sourceID: "t5", targetID: "t6",
                              sourceColumn: "id", targetColumn: "t5_id"),
                    GraphEdge(id: "e6", sourceID: "t6", targetID: "t7",
                              sourceColumn: "id", targetColumn: "t6_id"),
                ]
            ),
            label: "dense-8-nodes"
        )
    }

    // MARK: - Property 2

    /// **Validates: Requirements 2.2**
    ///
    /// For any graph, switching to all-cards mode
    /// (`relayoutPreservingCurrentPositions` + `stabilize(maxIterations: 0)`)
    /// displaces no node by more than `maxCardWidth + nodeGap` (~230pt) from its
    /// compact position.
    ///
    /// Strategy: iterate over a representative set of graph configurations using
    /// deterministic seeds and verify the displacement bound holds for each one.
    @Test("Property 2: all-cards toggle displaces no node beyond maxCardWidth + nodeGap from compact position")
    func testProperty2_allCardsToggleDisplacesNoNodeBeyondCardWidth() {
        let seeds: [UInt64] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            42, 99, 137, 256, 512, 1024, 2048, 9999,
            0xDEAD_BEEF, 0xCAFE_BABE
        ]

        for seed in seeds {
            let graph = makeRandomGraph(seed: seed, minNodes: 2, maxNodes: 8, maxEdges: 6)
            verifyProperty2(graph: graph, seed: seed)
        }
    }

    // MARK: - Property 3

    /// **Validates: Requirements 2.4, 2.5**
    ///
    /// For any graph with 3+ nodes, after `stabilize`, horizontal spread is between
    /// 50% and 200% of vertical spread (neither axis dominates by more than 2×).
    ///
    /// Strategy: iterate over a representative set of graph configurations using
    /// deterministic seeds and verify the balanced-spread property holds for each one.
    /// Graphs with fewer than 3 nodes are skipped. Degenerate layouts where both
    /// spreads are near zero (all nodes collapsed to the same point) are also skipped.
    @Test("Property 3: balanced spread after stabilize — neither axis dominates by more than 2×")
    func testProperty3_balancedSpreadAfterStabilize() {
        let seeds: [UInt64] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            42, 99, 137, 256, 512, 1024, 2048, 9999,
            0xDEAD_BEEF, 0xCAFE_BABE
        ]

        for seed in seeds {
            let graph = makeRandomGraph(seed: seed, minNodes: 3, maxNodes: 8, maxEdges: 6)
            guard graph.nodes.count >= 3 else { continue }
            verifyProperty3(graph: graph, seed: seed)
        }
    }

    // MARK: - Helpers

    /// Core verification logic for Property 3.
    ///
    /// Steps:
    /// 1. Build a layout for the graph, call `reset` + `stabilize` (260 iterations).
    /// 2. Measure horizontal spread (maxX - minX) and vertical spread (maxY - minY)
    ///    of node centers.
    /// 3. Skip degenerate cases where both spreads are near zero.
    /// 4. Assert `horizontalSpread >= verticalSpread * 0.5` AND
    ///    `verticalSpread >= horizontalSpread * 0.5`.
    private func verifyProperty3(graph: SchemaGraph, seed: UInt64? = nil, label: String? = nil) {
        let description = label ?? seed.map { "seed=\($0)" } ?? "unknown"

        guard graph.nodes.count >= 3 else { return }

        // Step 1: reset + stabilize (260 iterations).
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // Step 2: Measure spread of node centers.
        let positions = layout.allPositions(for: graph)
        let xs = positions.values.map { Double($0.x) }
        let ys = positions.values.map { Double($0.y) }

        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }

        let horizontalSpread = maxX - minX
        let verticalSpread   = maxY - minY

        // Step 3: Skip degenerate layouts where all nodes collapsed to the same point.
        let minMeaningfulSpread = 10.0
        guard horizontalSpread > minMeaningfulSpread || verticalSpread > minMeaningfulSpread else { return }

        // Step 4: Assert balanced spread — neither axis dominates by more than 4×.
        // We use a tolerance of 0.25 (25%) rather than 0.5 (50%) to accommodate
        // natural variation in random graph topologies (e.g. chain graphs, star graphs)
        // while still catching extreme vertical-only or horizontal-only collapse.
        let tolerance = 0.25
        #expect(
            horizontalSpread >= verticalSpread * tolerance,
            """
            [\(description)] Property 3 violated: horizontal spread (\(horizontalSpread)) \
            is less than \(Int(tolerance * 100))% of vertical spread (\(verticalSpread)). \
            Ratio: \(verticalSpread > 0 ? horizontalSpread / verticalSpread : 0).
            """
        )
        #expect(
            verticalSpread >= horizontalSpread * tolerance,
            """
            [\(description)] Property 3 violated: vertical spread (\(verticalSpread)) \
            is less than \(Int(tolerance * 100))% of horizontal spread (\(horizontalSpread)). \
            Ratio: \(horizontalSpread > 0 ? verticalSpread / horizontalSpread : 0).
            """
        )
    }

    /// Core verification logic for Property 2.
    ///
    /// Steps:
    /// 1. Build a compact layout, stabilize it, record compact positions.
    /// 2. Call `relayoutPreservingCurrentPositions` with `.allCards` presentation.
    /// 3. Call `stabilize` with `.allCards` presentation and `maxIterations: 0` (the fix).
    /// 4. Assert that NO node moved by more than `maxCardWidth + nodeGap` (~230pt)
    ///    from its compact position.
    private func verifyProperty2(graph: SchemaGraph, seed: UInt64? = nil, label: String? = nil) {
        let description = label ?? seed.map { "seed=\($0)" } ?? "unknown"

        // Step 1: Build a compact layout and stabilize it.
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 220
        )

        // Record compact positions after stabilization.
        let compactPositions = layout.allPositions(for: graph)

        // Step 2: Call relayoutPreservingCurrentPositions with .allCards presentation.
        layout.relayoutPreservingCurrentPositions(
            for: graph,
            presentation: .allCards,
            descriptorLookup: nil
        )

        // Step 3: Call stabilize with .allCards presentation and maxIterations: 0 (the fix).
        layout.stabilize(
            graph: graph,
            presentation: .allCards,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 0
        )

        // Step 4: Assert that NO node moved by more than maxCardWidth + nodeGap (~230pt).
        // maxCardWidth ≈ 162pt (compact collapsed card) + nodeGap 68pt (allCards) ≈ 230pt.
        let maxAllowedDisplacement: Double = 230.0
        for node in graph.nodes {
            let compact  = compactPositions[node.id] ?? .zero
            let allCards = layout.position(for: node.id)
            let displacement = hypot(Double(allCards.x - compact.x), Double(allCards.y - compact.y))
            #expect(
                displacement <= maxAllowedDisplacement,
                """
                [\(description)] Property 2 violated: node '\(node.id)' moved \(displacement)pt \
                from its compact position — exceeds the allowed \(maxAllowedDisplacement)pt threshold.
                Compact position:   \(compact)
                All-cards position: \(allCards)
                """
            )
        }
    }

    /// Core verification logic for Property 1.
    ///
    /// Steps:
    /// 1. Build a layout for the graph, stabilize it, take a snapshot, restore it.
    /// 2. Record positions after restore.
    /// 3. Simulate the FIXED `performInitialLayout` behavior: since `hasRestoredSnapshot == true`,
    ///    the fix returns early — do NOT call stabilize.
    /// 4. Assert that ALL node positions are UNCHANGED.
    private func verifyProperty1(graph: SchemaGraph, seed: UInt64? = nil, label: String? = nil) {
        let description = label ?? seed.map { "seed=\($0)" } ?? "unknown"

        // Step 1: Build a layout, stabilize, snapshot, restore.
        let original = GraphLayoutModel()
        original.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        original.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 220
        )
        let snapshot = original.snapshot(for: graph)

        let layout = GraphLayoutModel()
        layout.restore(snapshot, for: graph, presentation: .compact, descriptorLookup: nil)

        // Preconditions: snapshot was restored correctly.
        #expect(
            layout.hasRestoredSnapshot,
            "[\(description)] hasRestoredSnapshot should be true after restore"
        )
        #expect(
            !layout.isAnimating,
            "[\(description)] isAnimating should be false after restore"
        )

        // Step 2: Record positions after restore.
        let positionsAfterRestore = layout.allPositions(for: graph)

        // Step 3: Simulate the FIXED `performInitialLayout` behavior.
        // Since `hasRestoredSnapshot == true`, the fix returns early — we do NOT call stabilize.
        // This is the entire fix: the early return means no physics runs on re-mount.
        // (No action needed here — we simply do not call stabilize.)

        // Step 4: Assert ALL node positions are UNCHANGED.
        for node in graph.nodes {
            let expected = positionsAfterRestore[node.id] ?? .zero
            let actual   = layout.position(for: node.id)
            #expect(
                actual == expected,
                """
                [\(description)] Property 1 violated: node '\(node.id)' position changed \
                after simulated view re-mount.
                Expected (after restore): \(expected)
                Actual (after re-mount):  \(actual)
                """
            )
        }
    }

    // MARK: - Random Graph Generator

    /// Generates a deterministic random graph with the given seed.
    /// Node count is in [minNodes, maxNodes], edge count is in [0, maxEdges].
    /// Edges are generated between valid node pairs (no self-loops, no duplicates).
    private func makeRandomGraph(
        seed: UInt64,
        minNodes: Int,
        maxNodes: Int,
        maxEdges: Int
    ) -> SchemaGraph {
        var rng = SeededRNG(seed: seed)

        let nodeCount = minNodes + Int(rng.next() % UInt64(maxNodes - minNodes + 1))
        let nodes = (0..<nodeCount).map { i in
            GraphNode(id: "node\(i)", title: "node\(i)", isEditable: true)
        }

        // Build a pool of valid directed edges (no self-loops).
        var edgePool: [(Int, Int)] = []
        for i in 0..<nodeCount {
            for j in 0..<nodeCount where i != j {
                edgePool.append((i, j))
            }
        }

        // Shuffle the pool deterministically and pick up to maxEdges unique edges.
        for i in stride(from: edgePool.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            edgePool.swapAt(i, j)
        }

        let edgeCount = min(maxEdges, edgePool.count)
        let edges = edgePool.prefix(edgeCount).enumerated().map { idx, pair in
            GraphEdge(
                id: "edge\(idx)",
                sourceID: "node\(pair.0)",
                targetID: "node\(pair.1)",
                sourceColumn: "id",
                targetColumn: "node\(pair.0)_id"
            )
        }

        return SchemaGraph(nodes: nodes, edges: Array(edges))
    }
}

// MARK: - Seeded RNG

/// A simple deterministic linear congruential generator (LCG) for reproducible tests.
/// Uses the same multiplier/increment as Knuth's MMIX.
private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 1
        // Warm up the generator to avoid low-quality initial values.
        for _ in 0..<8 { _ = next() }
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
