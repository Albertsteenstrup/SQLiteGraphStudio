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
