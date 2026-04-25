import CoreGraphics
import Testing
@testable import StudioCore

struct GraphGeometryTests {
    @Test
    func expandedCardAnchorsResolveToForeignKeyAndReferencedRows() throws {
        let posts = makeDescriptor(name: "posts", columns: [
            makeColumn(name: "id", type: "INTEGER", primaryKeyOrdinal: 1),
            makeColumn(name: "author_id", type: "INTEGER"),
            makeColumn(name: "title", type: "TEXT"),
        ])
        let authors = makeDescriptor(name: "authors", columns: [
            makeColumn(name: "id", type: "INTEGER", primaryKeyOrdinal: 1),
            makeColumn(name: "name", type: "TEXT"),
        ])

        let edge = GraphEdge(
            id: "posts-authors",
            sourceID: "posts",
            targetID: "authors",
            sourceColumn: "author_id",
            targetColumn: "id"
        )

        let postsFrame = CGRect(
            x: 40,
            y: 60,
            width: GraphCardLayout.expandedWidth,
            height: GraphCardLayout.nodeSize(title: "posts", descriptor: posts, style: .expanded).height
        )
        let authorsFrame = CGRect(
            x: 420,
            y: 30,
            width: GraphCardLayout.expandedWidth,
            height: GraphCardLayout.nodeSize(title: "authors", descriptor: authors, style: .expanded).height
        )

        let anchorMap = GraphAnchorMap(
            nodeCards: [
                "posts": GraphCardGeometry(tableID: "posts", frame: postsFrame, role: .expandedNode, descriptor: posts),
                "authors": GraphCardGeometry(tableID: "authors", frame: authorsFrame, role: .expandedNode, descriptor: authors),
            ]
        )

        let anchors = try #require(anchorMap.edgeAnchors(for: edge))
        let expectedSource = try #require(GraphCardLayout.rowFrame(columnIndex: 1, in: postsFrame, role: .expandedNode))
        let expectedTarget = try #require(GraphCardLayout.rowFrame(columnIndex: 0, in: authorsFrame, role: .expandedNode))

        #expect(anchors.source.y == expectedSource.midY)
        #expect(anchors.target.y == expectedTarget.midY)
        #expect(anchors.source.x == expectedSource.maxX)
        #expect(anchors.target.x == expectedTarget.minX)
    }

    @Test
    func largerPresentationBoundsProduceSmallerFitZoom() {
        let compactBounds = CGRect(x: -220, y: -160, width: 440, height: 320)
        let expandedBounds = CGRect(x: -440, y: -320, width: 880, height: 640)
        let viewport = CGSize(width: 900, height: 700)

        let compactFit = GraphViewportTransform.fit(contentBounds: compactBounds, in: viewport)
        let expandedFit = GraphViewportTransform.fit(contentBounds: expandedBounds, in: viewport)

        #expect(expandedFit.zoom < compactFit.zoom)
    }

    @Test
    func focusTransformCentersExpandedTableWithinViewport() {
        let expandedBounds = CGRect(x: -140, y: -120, width: 320, height: 260)
        let viewport = CGSize(width: 960, height: 720)

        let transform = GraphViewportTransform.focus(
            contentBounds: expandedBounds,
            in: viewport,
            currentZoom: 0.52
        )
        let focusedRect = transform.rect(for: expandedBounds, in: viewport)
        let paddedViewport = CGRect(origin: .zero, size: viewport).insetBy(dx: 48, dy: 48)

        #expect(focusedRect.midX >= paddedViewport.minX)
        #expect(focusedRect.midX <= paddedViewport.maxX)
        #expect(focusedRect.midY >= paddedViewport.minY)
        #expect(focusedRect.midY <= paddedViewport.maxY)
        #expect(focusedRect.width <= paddedViewport.width)
        #expect(focusedRect.height <= paddedViewport.height)
    }

    @Test
    func hoveredCollapsedCardsExpandBeyondDefaultWidth() {
        let title = "this_is_a_long_table_name_for_a_hover_preview"

        let collapsed = GraphCardLayout.nodeSize(
            title: title,
            descriptor: nil,
            style: .collapsed,
            hovered: false
        )
        let hovered = GraphCardLayout.nodeSize(
            title: title,
            descriptor: nil,
            style: .collapsed,
            hovered: true
        )

        #expect(hovered.width > collapsed.width)
        #expect(hovered.height == collapsed.height)
    }

    @Test
    func expandedCardsCapVisibleRowsAtSeven() {
        let columns = (0..<12).map { index in
            makeColumn(name: "column_\(index)", type: "TEXT")
        }
        let descriptor = makeDescriptor(name: "large_table", columns: columns)

        let size = GraphCardLayout.nodeSize(
            title: "large_table",
            descriptor: descriptor,
            style: .expanded
        )

        let expectedHeight = GraphCardLayout.expandedHeaderHeight
            + GraphCardLayout.expandedBodyTopPadding
            + GraphCardLayout.expandedVerticalPadding
            + CGFloat(GraphCardLayout.maxExpandedVisibleRows) * GraphCardLayout.expandedRowHeight

        #expect(size.height == expectedHeight)
    }

    @Test
    func expandedCardGeometryOnlyExposesVisibleRows() {
        let columns = (0..<12).map { index in
            makeColumn(name: "column_\(index)", type: "TEXT")
        }
        let descriptor = makeDescriptor(name: "large_table", columns: columns)
        let frame = CGRect(
            x: 20,
            y: 30,
            width: GraphCardLayout.expandedWidth,
            height: GraphCardLayout.nodeSize(title: "large_table", descriptor: descriptor, style: .expanded).height
        )

        let geometry = GraphCardGeometry(
            tableID: "large_table",
            frame: frame,
            role: .expandedNode,
            descriptor: descriptor
        )

        #expect(geometry.rowFrames.count == GraphCardLayout.maxExpandedVisibleRows)
        #expect(geometry.rowFrames["column_6"] != nil)
        #expect(geometry.rowFrames["column_7"] == nil)
    }

    @Test
    func expandedCardGeometryHitTestsVisibleRowsInTopDownCoordinates() throws {
        let descriptor = makeDescriptor(name: "posts", columns: [
            makeColumn(name: "id", type: "INTEGER", primaryKeyOrdinal: 1),
            makeColumn(name: "author_id", type: "INTEGER"),
            makeColumn(name: "title", type: "TEXT"),
        ])
        let frame = CGRect(
            x: 40,
            y: 60,
            width: GraphCardLayout.expandedWidth,
            height: GraphCardLayout.nodeSize(title: "posts", descriptor: descriptor, style: .expanded).height
        )
        let geometry = GraphCardGeometry(
            tableID: "posts",
            frame: frame,
            role: .expandedNode,
            descriptor: descriptor
        )

        let idRow = try #require(geometry.rowFrames["id"])
        let authorRow = try #require(geometry.rowFrames["author_id"])

        #expect(geometry.columnName(at: CGPoint(x: idRow.midX, y: idRow.midY)) == "id")
        #expect(geometry.columnName(at: CGPoint(x: authorRow.midX, y: authorRow.midY)) == "author_id")
        #expect(geometry.columnName(at: CGPoint(x: frame.midX, y: frame.minY + 8)) == nil)
    }

    @Test
    func previewGeometryOnlyExposesRequestedColumns() throws {
        let descriptor = makeDescriptor(name: "post_tags", columns: [
            makeColumn(name: "post_id", type: "INTEGER"),
            makeColumn(name: "tag_id", type: "INTEGER"),
            makeColumn(name: "tagged_by", type: "INTEGER"),
        ])

        let frame = CGRect(
            x: 10,
            y: 20,
            width: GraphCardLayout.previewWidth,
            height: GraphCardLayout.nodeSize(
                title: "post_tags",
                descriptor: descriptor,
                style: .preview(rowCount: 1)
            ).height
        )

        let geometry = GraphCardGeometry(
            tableID: "post_tags",
            frame: frame,
            role: .previewNode,
            descriptor: descriptor,
            displayedColumns: ["tag_id"]
        )

        #expect(Set(geometry.rowFrames.keys) == ["tag_id"])
        let rowFrame = try #require(geometry.rowFrames["tag_id"])
        #expect(rowFrame.minY >= frame.minY)
        #expect(rowFrame.maxY <= frame.maxY)
    }

    // MARK: - Unit tests for bezierPoint and bezierTangent (Requirements 2.1, 2.2)

    /// Asserts `bezierPoint(t:0)` returns `start` and `bezierPoint(t:1)` returns `end`
    /// for a known curve with explicit control points.
    @Test("bezierPoint(t:0) returns start and bezierPoint(t:1) returns end for a known curve")
    func bezierPointEndpointsForKnownCurve() {
        let start    = CGPoint(x: 10, y: 20)
        let control1 = CGPoint(x: 50, y: 100)
        let control2 = CGPoint(x: 150, y: 100)
        let end      = CGPoint(x: 200, y: 20)

        let atZero = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 0)
        let atOne  = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 1)

        #expect(abs(atZero.x - start.x) < 1e-10, "bezierPoint(t:0).x should equal start.x (\(start.x)), got \(atZero.x)")
        #expect(abs(atZero.y - start.y) < 1e-10, "bezierPoint(t:0).y should equal start.y (\(start.y)), got \(atZero.y)")
        #expect(abs(atOne.x - end.x) < 1e-10, "bezierPoint(t:1).x should equal end.x (\(end.x)), got \(atOne.x)")
        #expect(abs(atOne.y - end.y) < 1e-10, "bezierPoint(t:1).y should equal end.y (\(end.y)), got \(atOne.y)")
    }

    /// Asserts that `bezierTangent` on a straight horizontal line returns a vector
    /// with zero (or negligible) vertical component at any parameter t.
    @Test("bezierTangent on a straight horizontal line has zero vertical component")
    func bezierTangentOnHorizontalLineHasZeroVerticalComponent() {
        // A straight horizontal line: all y-coordinates are equal.
        // Control points are collinear on y=0, so the tangent dy must be 0 everywhere.
        let start    = CGPoint(x: 0,   y: 0)
        let control1 = CGPoint(x: 50,  y: 0)
        let control2 = CGPoint(x: 150, y: 0)
        let end      = CGPoint(x: 200, y: 0)

        // Check at several parameter values including endpoints and midpoint
        let tValues: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        for t in tValues {
            let tangent = bezierTangent(start: start, control1: control1, control2: control2, end: end, t: t)
            #expect(
                abs(tangent.dy) < 1e-10,
                "bezierTangent at t=\(t) on horizontal line should have dy≈0, got dy=\(tangent.dy)"
            )
            // The horizontal component should be positive (curve goes left to right)
            #expect(
                tangent.dx > 0,
                "bezierTangent at t=\(t) on horizontal line should have dx>0, got dx=\(tangent.dx)"
            )
        }
    }

    // MARK: - Property-based tests

    /// **Validates: Requirements 2.1**
    ///
    /// Property 3: Bézier point at t=0 and t=1 are the endpoints.
    /// For any cubic Bézier curve (start, control1, control2, end),
    /// bezierPoint(t:0) must equal start and bezierPoint(t:1) must equal end.
    @Test("Feature: schema-graph-ux-improvements, Property 3: Bézier point at t=0 and t=1 are the endpoints")
    func bezierEndpointsMatchStartAndEnd() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let start    = randomCGPoint(using: &rng)
            let control1 = randomCGPoint(using: &rng)
            let control2 = randomCGPoint(using: &rng)
            let end      = randomCGPoint(using: &rng)

            let atZero = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 0)
            let atOne  = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 1)

            #expect(abs(atZero.x - start.x) < 1e-10, "bezierPoint(t:0).x should equal start.x")
            #expect(abs(atZero.y - start.y) < 1e-10, "bezierPoint(t:0).y should equal start.y")
            #expect(abs(atOne.x - end.x) < 1e-10, "bezierPoint(t:1).x should equal end.x")
            #expect(abs(atOne.y - end.y) < 1e-10, "bezierPoint(t:1).y should equal end.y")
        }
    }

    /// **Validates: Requirements 2.1**
    ///
    /// Property 4: Bézier midpoint is symmetric.
    /// bezierPoint(t:0.5) on the forward curve (start→end) must equal
    /// bezierPoint(t:0.5) on the reversed curve (end→start) with swapped control points.
    @Test("Feature: schema-graph-ux-improvements, Property 4: Bézier midpoint is symmetric")
    func bezierMidpointIsSymmetric() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let start    = randomCGPoint(using: &rng)
            let control1 = randomCGPoint(using: &rng)
            let control2 = randomCGPoint(using: &rng)
            let end      = randomCGPoint(using: &rng)

            let forward  = bezierPoint(start: start,  control1: control1, control2: control2, end: end,   t: 0.5)
            let reversed = bezierPoint(start: end,    control1: control2, control2: control1, end: start, t: 0.5)

            #expect(abs(forward.x - reversed.x) < 1e-10, "Midpoint x should be symmetric under curve reversal")
            #expect(abs(forward.y - reversed.y) < 1e-10, "Midpoint y should be symmetric under curve reversal")
        }
    }

    @Test
    func relationHoverHighlightsOnlyConnectedKeyRowsAndEdges() {
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
                GraphNode(id: "comments", title: "comments", isEditable: true),
            ],
            edges: [
                GraphEdge(id: "posts-authors", sourceID: "posts", targetID: "authors", sourceColumn: "author_id", targetColumn: "id"),
                GraphEdge(id: "comments-authors", sourceID: "comments", targetID: "authors", sourceColumn: "author_id", targetColumn: "id"),
                GraphEdge(id: "comments-posts", sourceID: "comments", targetID: "posts", sourceColumn: "post_id", targetColumn: "id"),
            ]
        )

        let primaryHover = GraphRelationHighlight(
            graph: graph,
            focusNodeID: nil,
            hoverTarget: GraphRelationHoverTarget(tableID: "authors", columnName: "id", endpointKind: .primary)
        )

        #expect(primaryHover.highlightedEdgeIDs == ["posts-authors", "comments-authors"])
        #expect(primaryHover.highlightState(for: "authors").style(for: "id") == .primary)
        #expect(primaryHover.highlightState(for: "posts").style(for: "author_id") == .foreign)
        #expect(primaryHover.highlightState(for: "comments").style(for: "author_id") == .foreign)
        #expect(primaryHover.highlightState(for: "comments").style(for: "post_id") == .none)

        let foreignHover = GraphRelationHighlight(
            graph: graph,
            focusNodeID: nil,
            hoverTarget: GraphRelationHoverTarget(tableID: "comments", columnName: "post_id", endpointKind: .foreign)
        )

        #expect(foreignHover.highlightedEdgeIDs == ["comments-posts"])
        #expect(foreignHover.highlightState(for: "comments").style(for: "post_id") == .foreign)
        #expect(foreignHover.highlightState(for: "posts").style(for: "id") == .primary)
        #expect(foreignHover.highlightState(for: "authors").style(for: "id") == .none)
    }

    @Test
    func relationRowHoverHighlightsBothEndpointKindsForMixedKeyColumn() {
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "memberships", title: "memberships", isEditable: true),
                GraphNode(id: "users", title: "users", isEditable: true),
                GraphNode(id: "invitations", title: "invitations", isEditable: true),
            ],
            edges: [
                GraphEdge(id: "memberships-users", sourceID: "memberships", targetID: "users", sourceColumn: "user_id", targetColumn: "id"),
                GraphEdge(id: "invitations-memberships", sourceID: "invitations", targetID: "memberships", sourceColumn: "membership_user_id", targetColumn: "user_id"),
            ]
        )

        let rowHover = GraphRelationHighlight(
            graph: graph,
            focusNodeID: nil,
            hoverTarget: GraphRelationHoverTarget(tableID: "memberships", columnName: "user_id", endpointKind: .column)
        )

        #expect(rowHover.highlightedEdgeIDs == ["memberships-users", "invitations-memberships"])
        #expect(rowHover.highlightState(for: "memberships").style(for: "user_id") == .both)
        #expect(rowHover.highlightState(for: "users").style(for: "id") == .primary)
        #expect(rowHover.highlightState(for: "invitations").style(for: "membership_user_id") == .foreign)
    }
}

private func makeDescriptor(name: String, columns: [TableColumn]) -> EditableTableDescriptor {
    EditableTableDescriptor(
        name: name,
        objectType: .table,
        columns: columns,
        primaryKeyColumns: columns.filter { $0.primaryKeyOrdinal > 0 }.map(\.name),
        rowIdentityStrategy: .primaryKey,
        isWithoutRowID: false,
        isEditable: true
    )
}

private func makeColumn(name: String, type: String, primaryKeyOrdinal: Int = 0) -> TableColumn {
    TableColumn(
        name: name,
        declaredType: type,
        notNull: false,
        defaultValueSQL: nil,
        primaryKeyOrdinal: primaryKeyOrdinal,
        hiddenValue: 0
    )
}

/// Returns a random `CGPoint` with coordinates in [-1000, 1000].
private func randomCGPoint(using rng: inout SystemRandomNumberGenerator) -> CGPoint {
    let range: CGFloat = 2000
    let x = CGFloat(rng.next(upperBound: UInt64(range * 1000))) / 1000 - range / 2
    let y = CGFloat(rng.next(upperBound: UInt64(range * 1000))) / 1000 - range / 2
    return CGPoint(x: x, y: y)
}
