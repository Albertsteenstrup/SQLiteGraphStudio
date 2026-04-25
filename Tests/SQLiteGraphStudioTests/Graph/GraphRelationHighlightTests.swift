import Testing
@testable import StudioCore

// MARK: - Generators

/// Generates a random `SchemaGraph` with `nodeCount` nodes and up to `maxEdges` edges.
/// Edges are created between randomly chosen distinct node pairs.
private func randomGraph(
    nodeCount: Int,
    maxEdges: Int,
    using rng: inout SystemRandomNumberGenerator
) -> SchemaGraph {
    guard nodeCount > 0 else { return SchemaGraph(nodes: [], edges: []) }

    let nodes = (0..<nodeCount).map { i in
        GraphNode(id: "node_\(i)", title: "table_\(i)", isEditable: true)
    }

    var edges: [GraphEdge] = []
    var usedPairs = Set<String>()
    let edgeCount = maxEdges > 0 ? Int.random(in: 0...maxEdges, using: &rng) : 0

    for e in 0..<edgeCount {
        let srcIdx = Int.random(in: 0..<nodeCount, using: &rng)
        var tgtIdx = Int.random(in: 0..<nodeCount, using: &rng)
        if tgtIdx == srcIdx { tgtIdx = (srcIdx + 1) % nodeCount }

        let srcID = nodes[srcIdx].id
        let tgtID = nodes[tgtIdx].id
        let pairKey = "\(srcID)->\(tgtID)"
        guard !usedPairs.contains(pairKey) else { continue }
        usedPairs.insert(pairKey)

        edges.append(GraphEdge(
            id: "edge_\(e)",
            sourceID: srcID,
            targetID: tgtID,
            sourceColumn: "fk_col",
            targetColumn: "pk_col"
        ))
    }

    return SchemaGraph(nodes: nodes, edges: edges)
}

// MARK: - Property Tests

struct GraphRelationHighlightTests {

    // MARK: Property 6

    /// **Validates: Requirements 8.1, 8.3**
    ///
    /// Property 6: Column highlight is absent when no badge is hovered.
    /// For any SchemaGraph and any focusNodeID, when hoverTarget is nil,
    /// highlightState(for:).primaryKeyColumns and .foreignKeyColumns must both be empty
    /// for every table ID.
    @Test("Feature: schema-graph-ux-improvements, Property 6: Column highlight is absent when no badge is hovered")
    func columnHighlightAbsentWhenNoBadgeHovered() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let nodeCount = Int.random(in: 1...6, using: &rng)
            let graph = randomGraph(nodeCount: nodeCount, maxEdges: 4, using: &rng)

            // Pick a random focusNodeID (or nil)
            let focusNodeID: String?
            if graph.nodes.isEmpty || Bool.random(using: &rng) {
                focusNodeID = nil
            } else {
                let idx = Int.random(in: 0..<graph.nodes.count, using: &rng)
                focusNodeID = graph.nodes[idx].id
            }

            let highlight = GraphRelationHighlight(
                graph: graph,
                focusNodeID: focusNodeID,
                hoverTarget: nil
            )

            for node in graph.nodes {
                let state = highlight.highlightState(for: node.id)
                #expect(
                    state.primaryKeyColumns.isEmpty,
                    "primaryKeyColumns should be empty when hoverTarget is nil"
                )
                #expect(
                    state.foreignKeyColumns.isEmpty,
                    "foreignKeyColumns should be empty when hoverTarget is nil"
                )
            }
        }
    }

    // MARK: Property 7

    /// **Validates: Requirements 8.4**
    ///
    /// Property 7: Edge highlight is present for expanded node.
    /// For any SchemaGraph with at least one edge, when focusNodeID == n and hoverTarget == nil,
    /// highlightedEdgeIDs must contain all edge IDs where sourceID == n || targetID == n.
    @Test("Feature: schema-graph-ux-improvements, Property 7: Edge highlight is present for expanded node")
    func edgeHighlightPresentForFocusedNode() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let nodeCount = Int.random(in: 2...6, using: &rng)
            let graph = randomGraph(nodeCount: nodeCount, maxEdges: 4, using: &rng)

            guard !graph.edges.isEmpty else { continue }

            // Pick a random node as the focus
            let idx = Int.random(in: 0..<graph.nodes.count, using: &rng)
            let focusNodeID = graph.nodes[idx].id

            let highlight = GraphRelationHighlight(
                graph: graph,
                focusNodeID: focusNodeID,
                hoverTarget: nil
            )

            let expectedEdgeIDs: Set<String> = Set(
                graph.edges
                    .filter { $0.sourceID == focusNodeID || $0.targetID == focusNodeID }
                    .map { $0.id }
            )

            for edgeID in expectedEdgeIDs {
                #expect(
                    highlight.highlightedEdgeIDs.contains(edgeID),
                    "highlightedEdgeIDs should contain edge connected to focusNodeID"
                )
            }
        }
    }

    // MARK: Property 8

    /// **Validates: Requirements 8.2**
    ///
    /// Property 8: Column highlight is present when badge is hovered.
    /// For any SchemaGraph and any GraphRelationHoverTarget targeting a column that participates
    /// in at least one edge, highlightState(for:) returns a non-empty highlight state for at
    /// least one table ID.
    @Test("Feature: schema-graph-ux-improvements, Property 8: Column highlight is present when badge is hovered")
    func columnHighlightPresentWhenBadgeHovered() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let nodeCount = Int.random(in: 2...6, using: &rng)
            let graph = randomGraph(nodeCount: nodeCount, maxEdges: 4, using: &rng)

            guard !graph.edges.isEmpty else { continue }

            // Pick a random edge and hover one of its endpoints
            let edgeIdx = Int.random(in: 0..<graph.edges.count, using: &rng)
            let edge = graph.edges[edgeIdx]

            // Alternate between hovering the primary (target) and foreign (source) endpoint
            let hoverTarget: GraphRelationHoverTarget
            if Bool.random(using: &rng) {
                hoverTarget = GraphRelationHoverTarget(
                    tableID: edge.targetID,
                    columnName: edge.targetColumn,
                    endpointKind: .primary
                )
            } else {
                hoverTarget = GraphRelationHoverTarget(
                    tableID: edge.sourceID,
                    columnName: edge.sourceColumn,
                    endpointKind: .foreign
                )
            }

            let highlight = GraphRelationHighlight(
                graph: graph,
                focusNodeID: nil,
                hoverTarget: hoverTarget
            )

            // At least one table should have a non-empty highlight state
            let anyHighlighted = graph.nodes.contains { node in
                let state = highlight.highlightState(for: node.id)
                return !state.primaryKeyColumns.isEmpty || !state.foreignKeyColumns.isEmpty
            }

            #expect(
                anyHighlighted,
                "At least one table should have a non-empty highlight state when a badge is hovered"
            )
        }
    }
}
