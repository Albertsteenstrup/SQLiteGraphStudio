import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

// MARK: - Preservation Property-Based Tests
//
// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7**
//
// Property 4a: For any graph, pinning a node at a position still results in that
// node being at the pinned position after `stabilize`.
//
// This test verifies that the drag-to-pin preservation property holds across a wide
// range of randomly-generated graph configurations. The fix must not break the
// existing pin-node behavior.

@MainActor
struct NodePositionStabilityPreservationTests {

    // MARK: - Property 4a

    /// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7**
    ///
    /// For any graph, pinning a node at a specific position still results in that
    /// node being at the pinned position after `stabilize` (260 iterations).
    ///
    /// Strategy: iterate over a representative set of graph configurations (varying
    /// node counts 3–8, edge counts 0–6) using deterministic seeds. For each graph:
    /// 1. Build a layout and stabilize it.
    /// 2. Pin one node at a known position (100, 200).
    /// 3. Call `stabilize` again (260 iterations).
    /// 4. Assert the pinned node is still at (100, 200) within floating-point tolerance.
    @Test("Property 4a: pinned node stays at pinned position after stabilize")
    func testProperty4a_pinnedNodeStaysPinnedAfterStabilize() {
        let seeds: [UInt64] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            42, 99, 137, 256, 512, 1024, 2048, 9999,
            0xDEAD_BEEF, 0xCAFE_BABE
        ]

        for seed in seeds {
            let graph = makeRandomGraph(seed: seed, minNodes: 3, maxNodes: 8, maxEdges: 6)
            verifyProperty4a(graph: graph, seed: seed)
        }

        // Hand-crafted topologies covering important edge cases:

        // Star topology — hub is pinned
        verifyProperty4a(
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
            pinnedNodeID: "hub",
            label: "star-topology-hub-pinned"
        )

        // Chain topology — middle node is pinned
        verifyProperty4a(
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
            pinnedNodeID: "n3",
            label: "chain-topology-middle-pinned"
        )

        // Fully disconnected — isolated node is pinned
        verifyProperty4a(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "x", title: "x", isEditable: true),
                    GraphNode(id: "y", title: "y", isEditable: true),
                    GraphNode(id: "z", title: "z", isEditable: true),
                ],
                edges: []
            ),
            pinnedNodeID: "y",
            label: "fully-disconnected-isolated-pinned"
        )

        // Dense graph — leaf node is pinned
        verifyProperty4a(
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
            pinnedNodeID: "t8",
            label: "dense-8-nodes-leaf-pinned"
        )
    }

    // MARK: - Property 4b

    /// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7**
    ///
    /// For any graph, calling `relayout` (reset + stabilize) still produces a layout
    /// where `isAnimating` starts `true` (after reset) and settles to `false` after
    /// `stabilize` (260 iterations).
    ///
    /// Strategy: iterate over a representative set of random graph configurations
    /// (2–8 nodes, 0–6 edges) using deterministic seeds. For each graph:
    /// 1. Call `reset` — assert `isAnimating == true`.
    /// 2. Call `stabilize` (260 iterations) — assert `isAnimating == false`.
    @Test("Property 4b: relayout animates then settles (isAnimating true→false)")
    func testProperty4b_relayoutAnimatesAndSettles() {
        let seeds: [UInt64] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            42, 99, 137, 256, 512, 1024, 2048, 9999,
            0xDEAD_BEEF, 0xCAFE_BABE
        ]

        for seed in seeds {
            let graph = makeRandomGraph(seed: seed, minNodes: 2, maxNodes: 8, maxEdges: 6)
            verifyProperty4b(graph: graph, label: "seed=\(seed)")
        }

        // Hand-crafted edge cases:

        // Minimal graph — 2 nodes, no edges
        verifyProperty4b(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "a", title: "a", isEditable: true),
                    GraphNode(id: "b", title: "b", isEditable: true),
                ],
                edges: []
            ),
            label: "2-nodes-no-edges"
        )

        // Single edge
        verifyProperty4b(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "src", title: "src", isEditable: true),
                    GraphNode(id: "dst", title: "dst", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "e1", sourceID: "src", targetID: "dst",
                              sourceColumn: "id", targetColumn: "src_id"),
                ]
            ),
            label: "2-nodes-1-edge"
        )

        // Star topology
        verifyProperty4b(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "hub",   title: "hub",   isEditable: true),
                    GraphNode(id: "leaf1", title: "leaf1", isEditable: true),
                    GraphNode(id: "leaf2", title: "leaf2", isEditable: true),
                    GraphNode(id: "leaf3", title: "leaf3", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "h-l1", sourceID: "hub", targetID: "leaf1",
                              sourceColumn: "id", targetColumn: "hub_id"),
                    GraphEdge(id: "h-l2", sourceID: "hub", targetID: "leaf2",
                              sourceColumn: "id", targetColumn: "hub_id"),
                    GraphEdge(id: "h-l3", sourceID: "hub", targetID: "leaf3",
                              sourceColumn: "id", targetColumn: "hub_id"),
                ]
            ),
            label: "star-topology"
        )

        // Dense 8-node graph
        verifyProperty4b(
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

    // MARK: - Property 4c

    /// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7**
    ///
    /// For any graph and snapshot, `restore(_:for:presentation:descriptorLookup:)` sets
    /// `hasRestoredSnapshot = true` and all node positions match the snapshot positions.
    ///
    /// Strategy: iterate over a representative set of random graph configurations
    /// (2–8 nodes, 0–6 edges) using deterministic seeds. For each graph:
    /// 1. Build a layout and stabilize it (260 iterations).
    /// 2. Take a snapshot.
    /// 3. Restore the snapshot into a fresh `GraphLayoutModel`.
    /// 4. Assert `hasRestoredSnapshot == true`.
    /// 5. Assert all node positions match the snapshot positions within floating-point tolerance.
    @Test("Property 4c: restore sets hasRestoredSnapshot and positions match snapshot")
    func testProperty4c_snapshotRestoreSetsHasRestoredSnapshotAndMatchesPositions() {
        let seeds: [UInt64] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            42, 99, 137, 256, 512, 1024, 2048, 9999,
            0xDEAD_BEEF, 0xCAFE_BABE
        ]

        for seed in seeds {
            let graph = makeRandomGraph(seed: seed, minNodes: 2, maxNodes: 8, maxEdges: 6)
            verifyProperty4c(graph: graph, seed: seed)
        }

        // Hand-crafted topologies covering important edge cases:

        // Minimal graph — 2 nodes, no edges
        verifyProperty4c(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "a", title: "a", isEditable: true),
                    GraphNode(id: "b", title: "b", isEditable: true),
                ],
                edges: []
            ),
            label: "2-nodes-no-edges"
        )

        // Single edge
        verifyProperty4c(
            graph: SchemaGraph(
                nodes: [
                    GraphNode(id: "src", title: "src", isEditable: true),
                    GraphNode(id: "dst", title: "dst", isEditable: true),
                ],
                edges: [
                    GraphEdge(id: "e1", sourceID: "src", targetID: "dst",
                              sourceColumn: "id", targetColumn: "src_id"),
                ]
            ),
            label: "2-nodes-1-edge"
        )

        // Star topology
        verifyProperty4c(
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

        // Chain topology
        verifyProperty4c(
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

        // Dense 8-node graph with pinned positions in snapshot
        verifyProperty4c(
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

    // MARK: - Core Verification Logic

    /// Core verification logic for Property 4a.
    ///
    /// Steps:
    /// 1. Build a layout for the graph, stabilize it (260 iterations).
    /// 2. Pin the target node at (100, 200).
    /// 3. Call `stabilize` again (260 iterations) — physics runs with the pin active.
    /// 4. Assert the pinned node is still at (100, 200) within floating-point tolerance.
    private func verifyProperty4a(
        graph: SchemaGraph,
        seed: UInt64? = nil,
        pinnedNodeID: String? = nil,
        label: String? = nil
    ) {
        let description = label ?? seed.map { "seed=\($0)" } ?? "unknown"

        // Determine which node to pin: use the provided ID, or pick the first node.
        guard let targetNodeID = pinnedNodeID ?? graph.nodes.first?.id else {
            return  // Empty graph — nothing to test
        }

        // Verify the target node actually exists in the graph.
        guard graph.nodes.contains(where: { $0.id == targetNodeID }) else {
            return
        }

        // Step 1: Build a layout and stabilize it (260 iterations).
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // Step 2: Pin the target node at a specific position.
        let pinnedPosition = CGPoint(x: 100, y: 200)
        layout.pin(nodeID: targetNodeID, at: pinnedPosition)

        // Verify the pin was applied.
        let positionAfterPin = layout.position(for: targetNodeID)
        #expect(
            positionAfterPin == pinnedPosition,
            "[\(description)] Node '\(targetNodeID)' should be at pinned position immediately after pin()"
        )

        // Step 3: Call stabilize again (260 iterations) — physics runs with the pin active.
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // Step 4: Assert the pinned node is still at (100, 200) within floating-point tolerance.
        let positionAfterStabilize = layout.position(for: targetNodeID)
        let tolerance: CGFloat = 0.001

        #expect(
            abs(positionAfterStabilize.x - pinnedPosition.x) <= tolerance &&
            abs(positionAfterStabilize.y - pinnedPosition.y) <= tolerance,
            """
            [\(description)] Property 4a violated: pinned node '\(targetNodeID)' moved \
            after stabilize.
            Pinned at:          \(pinnedPosition)
            Position after stabilize: \(positionAfterStabilize)
            Δx: \(abs(positionAfterStabilize.x - pinnedPosition.x)), \
            Δy: \(abs(positionAfterStabilize.y - pinnedPosition.y))
            """
        )
    }

    /// Core verification logic for Property 4b.
    ///
    /// Steps:
    /// 1. Call `reset` on a fresh `GraphLayoutModel` — assert `isAnimating == true`.
    /// 2. Call `stabilize` (260 iterations) — assert `isAnimating == false`.
    private func verifyProperty4b(graph: SchemaGraph, label: String) {
        let layout = GraphLayoutModel()

        // Step 1: reset should set isAnimating = true (for non-empty graphs).
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        #expect(
            layout.isAnimating == true,
            """
            [\(label)] Property 4b violated: isAnimating should be true after reset, \
            but was \(layout.isAnimating).
            """
        )

        // Step 2: stabilize should settle isAnimating to false.
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )
        #expect(
            layout.isAnimating == false,
            """
            [\(label)] Property 4b violated: isAnimating should be false after stabilize, \
            but was \(layout.isAnimating).
            """
        )
    }

    /// Core verification logic for Property 4c.
    ///
    /// Steps:
    /// 1. Build a layout for the graph, stabilize it (260 iterations).
    /// 2. Take a snapshot.
    /// 3. Restore the snapshot into a fresh `GraphLayoutModel`.
    /// 4. Assert `hasRestoredSnapshot == true`.
    /// 5. Assert all node positions match the snapshot positions within floating-point tolerance.
    private func verifyProperty4c(
        graph: SchemaGraph,
        seed: UInt64? = nil,
        label: String? = nil
    ) {
        let description = label ?? seed.map { "seed=\($0)" } ?? "unknown"

        guard !graph.nodes.isEmpty else { return }

        // Step 1: Build a layout and stabilize it (260 iterations).
        let original = GraphLayoutModel()
        original.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        original.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // Step 2: Take a snapshot.
        let snapshot = original.snapshot(for: graph)

        // Step 3: Restore the snapshot into a fresh GraphLayoutModel.
        let restored = GraphLayoutModel()
        restored.restore(snapshot, for: graph, presentation: .compact, descriptorLookup: nil)

        // Step 4: Assert hasRestoredSnapshot == true.
        #expect(
            restored.hasRestoredSnapshot == true,
            "[\(description)] Property 4c violated: hasRestoredSnapshot should be true after restore, but was false."
        )

        // Step 5: Assert all node positions match the snapshot positions.
        let tolerance: CGFloat = 0.001
        for node in graph.nodes {
            guard let snapshotPosition = snapshot.positions[node.id] else {
                // Node not in snapshot — skip (snapshot only contains valid node IDs).
                continue
            }
            let restoredPosition = restored.position(for: node.id)
            #expect(
                abs(restoredPosition.x - snapshotPosition.x) <= tolerance &&
                abs(restoredPosition.y - snapshotPosition.y) <= tolerance,
                """
                [\(description)] Property 4c violated: node '\(node.id)' position after restore \
                does not match snapshot position.
                Snapshot position:  \(snapshotPosition)
                Restored position:  \(restoredPosition)
                Δx: \(abs(restoredPosition.x - snapshotPosition.x)), \
                Δy: \(abs(restoredPosition.y - snapshotPosition.y))
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
