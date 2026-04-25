import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

// MARK: - Exploratory Bug Condition Tests
//
// These tests confirm the bugs exist on UNFIXED code.
// They are expected to PASS on unfixed code and FAIL on fixed code.
//
// Task 1.1: Full-screen toggle re-mount resets node positions (Bug 1)

@MainActor
struct NodePositionStabilityExploratoryTests {

    // MARK: - Bug 2: "Show all Table Cards" toggle re-runs physics on compact positions

    /// Simulates what `switchPresentationMode(isShowingAllCards: true)` currently does:
    /// it calls `relayoutPreservingCurrentPositions` (correct) then `stabilize` with
    /// `allCards` parameters and 140 iterations, which aggressively moves nodes far from
    /// their compact positions.
    ///
    /// This test is expected to PASS on unfixed code (confirming the bug exists)
    /// and FAIL on fixed code (where only overlap resolution runs, not a full physics pass).
    @Test("Bug 2: Show all Table Cards toggle resets node positions (expected to pass on unfixed code)")
    func testBug2_showAllCardsToggleResetsPositions() {
        // 1. Create a multi-node graph (6 nodes with edges)
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "users",    title: "users",    isEditable: true),
                GraphNode(id: "posts",    title: "posts",    isEditable: true),
                GraphNode(id: "comments", title: "comments", isEditable: true),
                GraphNode(id: "tags",     title: "tags",     isEditable: true),
                GraphNode(id: "likes",    title: "likes",    isEditable: true),
                GraphNode(id: "sessions", title: "sessions", isEditable: true),
            ],
            edges: [
                GraphEdge(id: "posts-users",      sourceID: "posts",    targetID: "users",    sourceColumn: "user_id",    targetColumn: "id"),
                GraphEdge(id: "comments-posts",   sourceID: "comments", targetID: "posts",    sourceColumn: "post_id",    targetColumn: "id"),
                GraphEdge(id: "likes-posts",      sourceID: "likes",    targetID: "posts",    sourceColumn: "post_id",    targetColumn: "id"),
                GraphEdge(id: "tags-posts",       sourceID: "tags",     targetID: "posts",    sourceColumn: "post_id",    targetColumn: "id"),
                GraphEdge(id: "sessions-users",   sourceID: "sessions", targetID: "users",    sourceColumn: "user_id",    targetColumn: "id"),
            ]
        )

        // 2. Build a compact layout and stabilize it so nodes are well-separated
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // 3. Record compact positions
        let compactPositions = layout.allPositions(for: graph)

        // 4. Call relayoutPreservingCurrentPositions to seed allCards positions from compact
        layout.relayoutPreservingCurrentPositions(
            for: graph,
            presentation: .allCards,
            descriptorLookup: nil
        )

        // 5. Call stabilize with allCards presentation and maxIterations: 140
        //    (this is what the current buggy code does in switchPresentationMode)
        layout.stabilize(
            graph: graph,
            presentation: .allCards,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 140
        )

        // 6. Record allCards positions after stabilization
        let allCardsPositions = layout.allPositions(for: graph)

        // 7. Assert that at least one node moved significantly (more than ~200pt, one compact card width)
        //    from its compact position — confirming the bug exists on unfixed code.
        //    On fixed code, only overlap resolution runs (maxIterations: 0), so nodes stay near
        //    their compact positions and this assertion will FAIL (desired outcome after the fix).
        let compactCardWidth: Double = 200.0  // approximately one compact card width
        let anyNodeMovedSignificantly = graph.nodes.contains { node in
            let compact   = compactPositions[node.id]   ?? .zero
            let allCards  = allCardsPositions[node.id]  ?? .zero
            let displacement = hypot(allCards.x - compact.x, allCards.y - compact.y)
            return displacement > compactCardWidth
        }

        #expect(
            anyNodeMovedSignificantly,
            """
            Bug 2 confirmed: at least one node moved more than \(compactCardWidth)pt after \
            relayoutPreservingCurrentPositions + stabilize(allCards, maxIterations: 140).
            Compact positions:   \(compactPositions)
            All-cards positions: \(allCardsPositions)
            """
        )
    }

    // MARK: - Bug 3: Physics engine spreads nodes too much vertically

    /// Calls `reset` + `stabilize` on a graph and measures the horizontal and
    /// vertical spread of node centers.
    ///
    /// The unfixed physics engine has two sources of vertical bias:
    ///   1. `resolveRemainingOverlaps` uses `separateOnX = overlapX <= overlapY`, which
    ///      favours Y-axis separation when the vertical overlap is smaller (common on
    ///      circular initial placements).
    ///   2. `limitSpreadIfNeeded` uses a much tighter height cap than width cap
    ///      (`max(480, n*90)` vs `max(900, n*200)`), compressing the layout vertically.
    ///
    /// This test is expected to PASS on unfixed code (confirming the bug exists)
    /// and FAIL on fixed code (where the spread is balanced).
    @Test("Bug 3: Physics engine spreads nodes too much vertically (expected to pass on unfixed code)")
    func testBug3_verticalBiasInPhysicsEngine() {
        // 1. Create a 6-node graph with a star topology (one hub, five leaves).
        //    The hub is the most-connected node and gets placed at the center.
        //    All leaves are placed in the same layer (ring around the hub).
        //    The overlap correction in the unfixed engine preferentially resolves
        //    overlaps on the Y axis, pushing the ring into a vertical column.
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "hub",   title: "hub",   isEditable: true),
                GraphNode(id: "leaf1", title: "leaf1", isEditable: true),
                GraphNode(id: "leaf2", title: "leaf2", isEditable: true),
                GraphNode(id: "leaf3", title: "leaf3", isEditable: true),
                GraphNode(id: "leaf4", title: "leaf4", isEditable: true),
                GraphNode(id: "leaf5", title: "leaf5", isEditable: true),
            ],
            edges: [
                GraphEdge(id: "hub-leaf1", sourceID: "hub", targetID: "leaf1", sourceColumn: "id", targetColumn: "hub_id"),
                GraphEdge(id: "hub-leaf2", sourceID: "hub", targetID: "leaf2", sourceColumn: "id", targetColumn: "hub_id"),
                GraphEdge(id: "hub-leaf3", sourceID: "hub", targetID: "leaf3", sourceColumn: "id", targetColumn: "hub_id"),
                GraphEdge(id: "hub-leaf4", sourceID: "hub", targetID: "leaf4", sourceColumn: "id", targetColumn: "hub_id"),
                GraphEdge(id: "hub-leaf5", sourceID: "hub", targetID: "leaf5", sourceColumn: "id", targetColumn: "hub_id"),
            ]
        )

        // 2. Reset and stabilize the layout
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // 3. Measure horizontal and vertical spread of node centers
        let positions = layout.allPositions(for: graph)
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)

        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0

        let horizontalSpread = Double(maxX - minX)
        let verticalSpread   = Double(maxY - minY)

        // 4. Assert that vertical spread exceeds horizontal spread by more than 2×
        //    — confirming the vertical bias bug exists on unfixed code.
        //    On fixed code the spread is balanced (neither axis dominates by more than 2×),
        //    so this assertion will FAIL (which is the desired outcome after the fix).
        #expect(
            verticalSpread > horizontalSpread * 2.0,
            """
            Bug 3 confirmed: vertical spread (\(verticalSpread)) exceeds horizontal spread \
            (\(horizontalSpread)) by more than 2×, demonstrating the vertical bias in the \
            unfixed physics engine.
            Node positions: \(positions)
            """
        )
    }

    // MARK: - Bug 1: Full-screen toggle re-runs physics on settled layout

    /// Simulates what `performInitialLayout` currently does when `hasRestoredSnapshot == true`:
    /// it calls `stabilize` with the current parameters, which moves nodes.
    ///
    /// This test is expected to PASS on unfixed code (confirming the bug exists)
    /// and FAIL on fixed code (where `performInitialLayout` returns early).
    @Test("Bug 1: Full-screen toggle re-mount resets node positions (expected to pass on unfixed code)")
    func testBug1_fullScreenToggleResetsPositions() {
        // 1. Create a multi-node graph
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "users",    title: "users",    isEditable: true),
                GraphNode(id: "posts",    title: "posts",    isEditable: true),
                GraphNode(id: "comments", title: "comments", isEditable: true),
                GraphNode(id: "tags",     title: "tags",     isEditable: true),
                GraphNode(id: "likes",    title: "likes",    isEditable: true),
            ],
            edges: [
                GraphEdge(id: "posts-users",    sourceID: "posts",    targetID: "users",    sourceColumn: "user_id",    targetColumn: "id"),
                GraphEdge(id: "comments-posts", sourceID: "comments", targetID: "posts",    sourceColumn: "post_id",    targetColumn: "id"),
                GraphEdge(id: "likes-posts",    sourceID: "likes",    targetID: "posts",    sourceColumn: "post_id",    targetColumn: "id"),
                GraphEdge(id: "tags-posts",     sourceID: "tags",     targetID: "posts",    sourceColumn: "post_id",    targetColumn: "id"),
            ]
        )

        // 2. Build an initial layout and take a snapshot (simulating a persisted layout)
        let original = GraphLayoutModel()
        original.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        original.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )
        let snapshot = original.snapshot(for: graph)

        // 3. Restore the snapshot into a fresh model (simulating app startup / database open)
        let layout = GraphLayoutModel()
        layout.restore(snapshot, for: graph, presentation: .compact, descriptorLookup: nil)

        // Confirm the snapshot was restored correctly
        #expect(layout.hasRestoredSnapshot, "hasRestoredSnapshot should be true after restore")
        #expect(!layout.isAnimating, "isAnimating should be false after restore")

        // 4. Record positions BEFORE the simulated re-mount
        let positionsBefore = layout.allPositions(for: graph)

        // 5. Simulate what performInitialLayout currently does when hasRestoredSnapshot == true:
        //    it calls stabilizeLayout(refit: false, persistLayout: false), which calls:
        //      session.graphLayout.stabilize(graph:presentation:descriptorLookup:nodeSizeLookup:maxIterations:260)
        //    We replicate that call directly here.
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        // 6. Record positions AFTER the simulated re-mount
        let positionsAfter = layout.allPositions(for: graph)

        // 7. Assert that positions CHANGED — this confirms the bug exists on unfixed code.
        //    On fixed code, performInitialLayout returns early and positions are unchanged,
        //    so this assertion will FAIL (which is the desired outcome after the fix).
        let anyNodeMoved = graph.nodes.contains { node in
            let before = positionsBefore[node.id] ?? .zero
            let after  = positionsAfter[node.id]  ?? .zero
            let displacement = hypot(after.x - before.x, after.y - before.y)
            return displacement > 1.0  // more than 1 pt movement counts as "moved"
        }

        #expect(
            anyNodeMoved,
            """
            Bug 1 confirmed: at least one node moved after simulating a full-screen toggle re-mount.
            Positions before: \(positionsBefore)
            Positions after:  \(positionsAfter)
            """
        )
    }
}
