import CoreGraphics
import Testing
@testable import StudioCore

@MainActor
struct GraphInteractionGeometryTests {
    @Test func detailHitWinsOverCanvasMarkerRegardlessOfMarkerOrdinal() {
        let snapshot = GraphInteractionGeometryCache().snapshot(
            frames: ["detail": CGRect(x: 20, y: 20, width: 60, height: 60),
                     "marker": CGRect(x: 20, y: 20, width: 60, height: 60)],
            viewport: viewport, zoom: 0.1, isLarge: true, emphasized: ["detail"], contentRevision: 0,
            roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
        )
        #expect(snapshot.renderPlan.detailIDs == ["detail"])
        #expect(snapshot.renderPlan.markerIDs == ["marker"])
        #expect(snapshot.topmostHit(at: CGPoint(x: 40, y: 40),
                                   zIndexForNode: { $0 == "marker" ? 4 : 0 },
                                   nodeIndexForNode: { $0 == "marker" ? 99 : 0 }) == "detail")
    }

    @Test func overlappingDetailHitsFollowVisualZIndexThenGraphOrder() {
        let snapshot = GraphInteractionGeometryCache().snapshot(
            frames: ["a": CGRect(x: 20, y: 20, width: 60, height: 60),
                     "b": CGRect(x: 20, y: 20, width: 60, height: 60)],
            viewport: viewport, zoom: 1, isLarge: false, emphasized: [], contentRevision: 0,
            roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
        )
        let point = CGPoint(x: 40, y: 40)
        #expect(snapshot.topmostHit(at: point, zIndexForNode: { _ in 1 },
                                   nodeIndexForNode: { $0 == "b" ? 1 : 0 }) == "b")
        #expect(snapshot.topmostHit(at: point, zIndexForNode: { $0 == "a" ? 4 : 1 },
                                   nodeIndexForNode: { $0 == "b" ? 1 : 0 }) == "a")
    }

    @Test(arguments: [581, 2_000])
    func offscreenTablesNeverConstructDescriptorOrRowGeometry(count: Int) {
        let cache = GraphInteractionGeometryCache()
        let frames = Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            ("n\(index)", CGRect(x: index < 12 ? 20 : 10_000 + index * 400, y: 20, width: 308, height: 236))
        })
        let descriptor = descriptor(columnCount: 100)
        var descriptorCalls = 0
        var columnCalls = 0
        let snapshot = cache.snapshot(
            frames: frames, viewport: viewport, zoom: 1, isLarge: true,
            emphasized: [], contentRevision: 1, roleForNode: { _ in .expandedNode },
            descriptorForNode: { _ in descriptorCalls += 1; return descriptor },
            displayedColumnsForNode: { _ in columnCalls += 1; return nil }
        )

        #expect(snapshot.frames.count == count)
        #expect(snapshot.anchorMap.nodeCards.count == count)
        #expect(snapshot.renderPlan.detailIDs.count == 12)
        #expect(descriptorCalls == 12)
        #expect(columnCalls == 12)
        #expect(snapshot.anchorMap.nodeCards.values.reduce(0) { $0 + $1.rowFrames.count } == 12 * GraphCardLayout.maxExpandedVisibleRows)
        #expect(snapshot.anchorMap.nodeCards["n500"]?.role == .collapsedNode)
        #expect(snapshot.anchorMap.nodeCards["n500"]?.rowFrames.isEmpty == true)
    }

    @Test(arguments: [581, 2_000])
    func overviewMarkersNeverReadDescriptorsOrColumns(count: Int) {
        let cache = GraphInteractionGeometryCache()
        let frames = Dictionary(uniqueKeysWithValues: (0..<count).map { ("n\($0)", CGRect(x: 40, y: 40, width: 3, height: 1)) })
        var descriptorCalls = 0
        var columnCalls = 0
        let snapshot = cache.snapshot(
            frames: frames, viewport: viewport, zoom: 0.08, isLarge: true,
            emphasized: [], contentRevision: 1, roleForNode: { _ in .expandedNode },
            descriptorForNode: { _ in descriptorCalls += 1; return nil },
            displayedColumnsForNode: { _ in columnCalls += 1; return ["id"] }
        )

        #expect(snapshot.renderPlan.markerIDs.count == count)
        #expect(snapshot.renderPlan.detailIDs.isEmpty)
        #expect(descriptorCalls == 0)
        #expect(columnCalls == 0)
        #expect(snapshot.anchorMap.nodeCards.values.allSatisfy { $0.role == .collapsedNode && $0.rowFrames.isEmpty })
    }

    @Test
    func detailConstructionIsBoundedWhenAllTwoThousandTablesAreVisible() {
        let cache = GraphInteractionGeometryCache()
        let frames = Dictionary(uniqueKeysWithValues: (0..<2_000).map { ("n\($0)", CGRect(x: 40, y: 40, width: 308, height: 236)) })
        let descriptor = descriptor(columnCount: 100)
        var descriptorCalls = 0
        let snapshot = cache.snapshot(
            frames: frames, viewport: viewport, zoom: 1, isLarge: true,
            emphasized: Set(frames.keys), contentRevision: 1, roleForNode: { _ in .expandedNode },
            descriptorForNode: { _ in descriptorCalls += 1; return descriptor }
        )

        #expect(descriptorCalls == GraphExploration.maximumDetailedCards)
        #expect(snapshot.renderPlan.detailIDs.count == GraphExploration.maximumDetailedCards)
        #expect(snapshot.anchorMap.nodeCards.values.reduce(0) { $0 + $1.rowFrames.count }
            == GraphExploration.maximumDetailedCards * GraphCardLayout.maxExpandedVisibleRows)
    }

    @Test
    func unchangedSnapshotReusesGeometryAndRevisionWithoutDetailReads() {
        let cache = GraphInteractionGeometryCache()
        let descriptor = descriptor(columnCount: 3)
        let frames = ["posts": CGRect(x: 40, y: 40, width: 308, height: 140)]
        var descriptorCalls = 0
        func snapshot(revision: Int = 1) -> GraphInteractionGeometry {
            cache.snapshot(
                frames: frames, viewport: viewport, zoom: 1, isLarge: false,
                emphasized: [], contentRevision: revision, roleForNode: { _ in .expandedNode },
                descriptorForNode: { _ in descriptorCalls += 1; return descriptor }
            )
        }
        let first = snapshot()
        for _ in 0..<100 {
            #expect(snapshot().revision == first.revision)
        }
        #expect(descriptorCalls == 1)

        let changed = snapshot(revision: 2)
        #expect(changed.revision != first.revision)
        #expect(descriptorCalls == 2)
    }

    @Test
    func viewportAndFrameChangesRefreshGeometryAndHitRevision() {
        let cache = GraphInteractionGeometryCache()
        let originalFrame = CGRect(x: 20, y: 20, width: 200, height: 46)
        let first = cache.snapshot(
            frames: ["posts": originalFrame], viewport: viewport, zoom: 1, isLarge: false,
            emphasized: [], contentRevision: 0, roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
        )
        let moved = cache.snapshot(
            frames: ["posts": originalFrame.offsetBy(dx: 600, dy: 0)], viewport: viewport, zoom: 1, isLarge: false,
            emphasized: [], contentRevision: 0, roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
        )

        #expect(moved.revision != first.revision)
        #expect(first.hitCandidates(at: CGPoint(x: 30, y: 30)) == ["posts"])
        #expect(moved.hitCandidates(at: CGPoint(x: 30, y: 30)).isEmpty)
        #expect(moved.hitCandidates(at: CGPoint(x: 630, y: 30)) == ["posts"])
    }

    @Test
    func retainedDragOutsideViewportKeepsDetailedCardAndRows() {
        let cache = GraphInteractionGeometryCache()
        let descriptor = descriptor(columnCount: 3)
        var descriptorCalls = 0
        let snapshot = cache.snapshot(
            frames: ["dragged": CGRect(x: 20_000, y: 20_000, width: 308, height: 140)],
            viewport: viewport, zoom: 1, isLarge: true, emphasized: [], retained: ["dragged", "missing"],
            contentRevision: 0, roleForNode: { _ in .expandedNode },
            descriptorForNode: { _ in descriptorCalls += 1; return descriptor }
        )

        #expect(snapshot.renderPlan.detailIDs == ["dragged"])
        #expect(snapshot.renderPlan.markerIDs.isEmpty)
        #expect(snapshot.anchorMap.nodeCards["dragged"]?.rowFrames.count == 3)
        #expect(descriptorCalls == 1)
    }

    @Test
    func markerHitUsesVisibleMinimumSizeAndHasNoRows() throws {
        let cache = GraphInteractionGeometryCache()
        let snapshot = cache.snapshot(
            frames: ["marker": CGRect(x: 40, y: 40, width: 0.2, height: 0.2)],
            viewport: viewport, zoom: 0.01, isLarge: true, emphasized: [], contentRevision: 0,
            roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in descriptor(columnCount: 100) }
        )
        let card = try #require(snapshot.anchorMap.nodeCards["marker"])

        #expect(snapshot.hitCandidates(at: CGPoint(x: 39, y: 39)) == ["marker"])
        #expect(snapshot.hitCandidates(at: CGPoint(x: 38, y: 38)).isEmpty)
        #expect(card.role == .collapsedNode)
        #expect(card.columnName(at: CGPoint(x: 40.1, y: 40.1)) == nil)
    }

    @Test
    func hitIndexFindsOnlyInteractiveFramesAcrossTwoThousandMarkers() {
        let cache = GraphInteractionGeometryCache()
        let frames = Dictionary(uniqueKeysWithValues: (0..<2_000).map { index in
            ("n\(index)", CGRect(x: (index % 50) * 20, y: (index / 50) * 20, width: 4, height: 4))
        })
        let snapshot = cache.snapshot(
            frames: frames, viewport: viewport, zoom: 0.08, isLarge: true, emphasized: [], contentRevision: 0,
            roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in nil }
        )

        for index in [0, 581, 1_999] {
            let frame = frames["n\(index)"]!
            #expect(snapshot.hitCandidates(at: CGPoint(x: frame.midX, y: frame.midY)) == ["n\(index)"])
        }
        #expect(snapshot.hitCandidates(at: CGPoint(x: 10, y: 10)).isEmpty)
        #expect(snapshot.hitCandidates(at: CGPoint(x: 50_000, y: 50_000)).isEmpty)
    }

    @Test
    func veryLargeInteractiveFrameDoesNotRequireUnboundedCellInsertion() {
        let cache = GraphInteractionGeometryCache()
        let snapshot = cache.snapshot(
            frames: ["large": CGRect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000)],
            viewport: viewport, zoom: 1, isLarge: false, emphasized: [], contentRevision: 0,
            roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
        )

        #expect(snapshot.hitCandidates(at: .zero) == ["large"])
        #expect(snapshot.hitCandidates(at: CGPoint(x: 2_000_000, y: 2_000_000)).isEmpty)
    }

    @Test
    func edgeToOffscreenTableKeepsVisibleRowAndRemoteRectAnchors() throws {
        let cache = GraphInteractionGeometryCache()
        let descriptor = descriptor(columnCount: 3)
        let frames = [
            "posts": CGRect(x: 40, y: 40, width: 308, height: 140),
            "authors": CGRect(x: 20_000, y: 40, width: 308, height: 140),
        ]
        let snapshot = cache.snapshot(
            frames: frames, viewport: viewport, zoom: 1, isLarge: true, emphasized: [], contentRevision: 0,
            roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in descriptor }
        )
        let relation = edge("posts", "authors", column: "column_1")
        let anchors = try #require(snapshot.anchorMap.edgeAnchors(for: relation))
        let visibleRow = try #require(snapshot.anchorMap.nodeCards["posts"]?.rowFrames["column_1"])

        #expect(anchors.source == CGPoint(x: visibleRow.maxX, y: visibleRow.midY))
        #expect(anchors.target == CGPoint(x: 20_000, y: 110))
        #expect(snapshot.hitCandidates(at: CGPoint(x: 20_100, y: 110)).isEmpty)
    }

    @Test
    func detailedScrolledColumnAnchorsRespectDisplayedColumnsAndZoom() throws {
        let cache = GraphInteractionGeometryCache()
        let snapshot = cache.snapshot(
            frames: ["posts": CGRect(x: 40, y: 40, width: 154, height: 118)],
            viewport: viewport, zoom: 0.5, isLarge: false, emphasized: [], contentRevision: 3,
            roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in descriptor(columnCount: 100) },
            displayedColumnsForNode: { _ in ["column_8", "column_9"] }
        )
        let card = try #require(snapshot.anchorMap.nodeCards["posts"])
        let row = try #require(card.rowFrames["column_8"])

        #expect(Set(card.rowFrames.keys) == ["column_8", "column_9"])
        #expect(row == GraphCardLayout.rowFrame(columnIndex: 0, in: card.frame, role: .expandedNode, scale: 0.5))
    }

    @Test
    func collapsedCardGeometryNeverEvaluatesDescriptorExpression() {
        var descriptorCalls = 0
        func expensiveDescriptor() -> EditableTableDescriptor {
            descriptorCalls += 1
            return descriptor(columnCount: 1_000)
        }
        let card = GraphCardGeometry(
            tableID: "posts", frame: CGRect(x: 0, y: 0, width: 200, height: 46), role: .collapsedNode,
            descriptor: expensiveDescriptor(), displayedColumns: ["column_1"]
        )

        #expect(descriptorCalls == 0)
        #expect(card.rowFrames.isEmpty)
    }

    @Test
    func cheapFrameTransformsPreserveSuppliedPositionsAndDeduplicateIDs() {
        var sizeCalls = 0
        let world = GraphInteractionGeometry.worldFrames(
            nodeIDs: ["pinned", "pinned"], positionForNode: { _ in CGPoint(x: 100, y: -50) },
            sizeForNode: { _ in sizeCalls += 1; return CGSize(width: 200, height: 46) }
        )
        let screen = GraphInteractionGeometry.screenFrames(
            worldFrames: world, transform: GraphViewportTransform(zoom: 0.5, pan: CGSize(width: 10, height: 20)),
            viewportSize: CGSize(width: 800, height: 600)
        )

        #expect(sizeCalls == 1)
        #expect(world["pinned"] == CGRect(x: 0, y: -73, width: 200, height: 46))
        #expect(screen["pinned"] == CGRect(x: 410, y: 283.5, width: 100, height: 23))
    }

    @Test
    func topologyLookupReusesIndexUntilExplicitGraphRevisionChanges() {
        let cache = GraphTopologyCache()
        let graph = graph(["second", "first"], edges: [edge("second", "first")])
        let first = cache.index(for: graph, graphRevision: 1)
        for _ in 0..<100 {
            #expect(cache.index(for: graph, graphRevision: 1) === first)
        }
        let next = cache.index(for: graph, graphRevision: 2)

        #expect(next !== first)
        #expect(first.outgoingEdges(for: "second").count == 1)
        #expect(first.incomingEdges(for: "first").count == 1)
        #expect(first.nodeIndex(for: "second") == 0)
        #expect(first.nodeIndex(for: "first") == 1)
        #expect(first.nodeIndex(for: "missing") == nil)
    }

    @Test
    func topologyKeepsNaturalRelationOrderingAndQualifiedTableIDs() {
        let cache = GraphTopologyCache()
        let relations = [
            edge("public.posts", "archive.users", column: "key_10"),
            edge("public.posts", "public.users", column: "key_2"),
        ]
        let index = cache.index(for: graph(["public.posts", "archive.users", "public.users"], edges: relations), graphRevision: 1)

        #expect(index.outgoingEdges(for: "public.posts").map(\.sourceColumn) == ["key_2", "key_10"])
        #expect(index.incomingEdges(for: "archive.users").map(\.sourceColumn) == ["key_10"])
        #expect(index.incomingEdges(for: "public.users").map(\.sourceColumn) == ["key_2"])
    }

    @Test
    func groupLinksRefreshOnGroupingRevisionWithoutRebuildingEdgeIndex() {
        let cache = GraphTopologyCache()
        let graph = graph(["a", "b"], edges: [edge("a", "b")])
        let index = cache.index(for: graph, graphRevision: 1)
        let first = cache.groupLinks(for: graph, graphRevision: 1, membership: ["a": "one", "b": "two"], groupingRevision: 1)
        let linksRevision = cache.groupLinksRevision
        let unchanged = cache.groupLinks(for: graph, graphRevision: 1, membership: ["a": "one", "b": "two"], groupingRevision: 1)

        #expect(first == unchanged)
        #expect(first.count == 1)
        #expect(cache.groupLinksRevision == linksRevision)
        #expect(cache.groupLinks(for: graph, graphRevision: 1, membership: ["a": "one", "b": "one"], groupingRevision: 2).isEmpty)
        #expect(cache.groupLinksRevision != linksRevision)
        #expect(cache.index(for: graph, graphRevision: 1) === index)
    }

    private var viewport: CGRect { CGRect(x: 0, y: 0, width: 1_000, height: 800) }

    private func descriptor(columnCount: Int) -> EditableTableDescriptor {
        EditableTableDescriptor(
            name: "sample", objectType: .table,
            columns: (0..<columnCount).map { TableColumn(name: "column_\($0)", declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0) },
            primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false
        )
    }

    private func graph(_ ids: [String], edges: [GraphEdge]) -> SchemaGraph {
        SchemaGraph(nodes: ids.map { GraphNode(id: $0, title: $0, isEditable: false) }, edges: edges)
    }

    private func edge(_ source: String, _ target: String, column: String = "column_0") -> GraphEdge {
        GraphEdge(id: "\(source)-\(target)-\(column)", sourceID: source, targetID: target, sourceColumn: column, targetColumn: "column_0")
    }
}
