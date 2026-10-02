import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import StudioCore

@MainActor
struct GraphNodeSizingTests {
    private func table(_ name: String, fields: Int = 8, rows: Int? = nil) -> TableSummary {
        TableSummary(name: name, objectType: .table, isEditable: true, columnCount: fields, rowCount: rows)
    }

    @Test func sizingDataDistinguishesMissingRowsFromZeroAndCountsDeclaredLinks() {
        let tables = [table("empty", fields: 2, rows: 0), table("estimated", fields: 20, rows: 500),
                      table("unknown", fields: 8)]
        let data = GraphNodeSizeData(tables: tables, rowCounts: ["estimated": 10],
                                     relationCounts: ["empty": 2, "unknown": 1])
        #expect(data.objectCount == 3)
        #expect(data.minimumFields == 2 && data.maximumFields == 20)
        #expect(data.availableRowCounts == 2)
        #expect(data.minimumRows == 0 && data.maximumRows == 10)
        #expect(data.connectedObjects == 2 && data.maximumRelations == 2)
        let schemaOnly = GraphNodeSizeData(tables: tables.map { table($0.name, fields: $0.columnCount) },
                                           rowCounts: [:], relationCounts: [:])
        #expect(schemaOnly.availableRowCounts == 0 && schemaOnly.minimumRows == nil)
    }

    @Test func fieldsRowsAndRelationsUseTheirOwnCountsAndUnknownIsNotZero() throws {
        let tables = [table("a", fields: 2, rows: 0), table("b", fields: 20, rows: 1_000_000), table("c", fields: 8)]
        let fields = GraphNodeSizeProfile(metric: .fields, tables: tables, rowCounts: [:], relationCounts: ["a": 10, "b": 1])
        let rows = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: [:], relationCounts: [:])
        let relations = GraphNodeSizeProfile(metric: .relations, tables: tables, rowCounts: [:], relationCounts: ["a": 10, "b": 1])
        #expect(fields.areas["a"]! < fields.areas["c"]! && fields.areas["c"]! < fields.areas["b"]!)
        #expect(rows.areas["a"] == 0.12)
        #expect(rows.areas["b"] == 1)
        #expect(rows.areas["c"] == nil && rows.unknownIDs == ["c"])
        #expect(relations.areas["a"]! > relations.areas["b"]! && relations.areas["b"]! > relations.areas["c"]!)
        #expect(relations.unknownIDs.isEmpty)
        let counted = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: ["c": 0, "b": 10], relationCounts: [:])
        #expect(counted.unknownIDs.isEmpty)
        #expect(counted.areas["c"] == counted.areas["a"])
        #expect(counted.areas["b"] == 1)
    }

    @Test func logarithmicCompressionHandlesZeroOutliersAndMissingMetadata() {
        let tables = [table("zero", rows: 0), table("one", rows: 1), table("many", rows: 10_000),
                      table("huge", rows: Int.max), table("negative", rows: -1), table("unknown")]
        let profile = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: [:], relationCounts: [:])
        #expect(profile.unknownIDs == ["negative", "unknown"])
        #expect(profile.areas.values.allSatisfy { $0.isFinite && (0.12...1).contains($0) })
        #expect(profile.areas["one"]! < profile.areas["many"]!)
        #expect(profile.areas["many"]! > 0.2) // Still visible beside a 64-bit outlier.
        let empty = GraphNodeSizeProfile(metric: .rows, tables: [], rowCounts: [:], relationCounts: [:])
        #expect(empty.areas.isEmpty && empty.unknownIDs.isEmpty)
    }

    @Test func zoomInRestoresOriginalSizesAndZoomOutStrengthensDifferences() {
        let tables = [table("small", fields: 1), table("large", fields: 100)]
        let profile = GraphNodeSizeProfile(metric: .fields, tables: tables, rowCounts: [:], relationCounts: [:])
        var previousRatio: CGFloat = 1
        for zoom: CGFloat in [0.42, 0.38, 0.3, 0.2, 0.1, 0.08] {
            let frame = CGRect(x: 200, y: 200, width: 380 * zoom, height: 46 * zoom)
            let small = profile.markerFrame(for: "small", frame: frame, zoom: zoom)
            let large = profile.markerFrame(for: "large", frame: frame, zoom: zoom)
            #expect(abs(small.midX - frame.midX) < 0.000001 && abs(small.midY - frame.midY) < 0.000001)
            #expect(abs(large.midX - frame.midX) < 0.000001 && abs(large.midY - frame.midY) < 0.000001)
            #expect(frame.contains(small))
            if zoom < GraphExploration.detailZoom { #expect(large.width > frame.width) }
            let ratio = large.width / small.width
            #expect(ratio >= previousRatio)
            previousRatio = ratio
        }
        let frame = CGRect(x: 20, y: 20, width: 150, height: 30)
        #expect(profile.markerFrame(for: "small", frame: frame, zoom: 0.42) == frame)
        #expect(profile.markerFrame(for: "small", frame: frame, zoom: 1) == frame)
        #expect(GraphNodeSizeProfile.uniform.markerFrame(for: "small", frame: frame, zoom: 0.1) == frame)
        #expect(GraphNodeSizeProfile.emphasis(at: .nan) == 0)
    }

    @Test(arguments: [GraphNodeSizeMetric.fields, .rows, .relations])
    func overviewSizesUseTheFullRangeAndGrowBeyondUniform(metric: GraphNodeSizeMetric) {
        let tables = [table("small", fields: 18, rows: 18), table("large", fields: 20, rows: 20), table("unknown")]
        let profile = GraphNodeSizeProfile(metric: metric, tables: Array(tables.prefix(2)), rowCounts: [:],
                                          relationCounts: ["small": 18, "large": 20])
        let zoom: CGFloat = 0.05
        let uniform = CGRect(x: 0, y: 0, width: 226 * zoom, height: 46 * zoom)
        let small = profile.markerFrame(for: "small", frame: uniform, zoom: zoom)
        let large = profile.markerFrame(for: "large", frame: uniform, zoom: zoom)
        #expect(large.width > uniform.width * 2.8)
        #expect(small.width < uniform.width * 0.6)
        #expect(large.width / small.width > 4.5)
        #expect(profile.dimensionScale(for: "unknown") == 1)
    }

    @Test func equalCountsKeepANeutralSize() {
        let profile = GraphNodeSizeProfile(metric: .fields, tables: [table("a"), table("b")],
                                          rowCounts: [:], relationCounts: [:])
        let frame = CGRect(x: 0, y: 0, width: 226 * 0.1, height: 46 * 0.1)
        #expect(profile.markerFrame(for: "a", frame: frame, zoom: 0.1) == frame)
        #expect(profile.markerFrame(for: "b", frame: frame, zoom: 0.1) == frame)
    }

    @Test func changingMetricMovesNeighboursAndKeepsRenderedMarkersApart() {
        let tables = [table("hub", fields: 100), table("left", fields: 1), table("right", fields: 1),
                      table("above", fields: 1), table("below", fields: 1), table("distant", fields: 1)]
        let graph = SchemaGraph(nodes: tables.map { GraphNode(id: $0.id, title: $0.name, isEditable: true) }, edges: [])
        let original = ["hub": CGPoint.zero, "left": CGPoint(x: -250, y: 0), "right": CGPoint(x: 250, y: 0),
                        "above": CGPoint(x: 0, y: -74), "below": CGPoint(x: 0, y: 74), "distant": CGPoint(x: 2_000, y: 2_000)]
        let session = AppSession()
        session.graphNodeSizeMetric = .uniform
        session.tables = tables
        session.graph = graph
        session.graphZoom = 0.05
        session.graphLayout.restore(.init(positions: original, pinnedPositions: [:]), for: graph,
                                    presentation: .compact, descriptorLookup: nil)
        session.setGraphNodeSizeMetric(.fields, persist: false)
        let moved = session.graphLayout.allPositions(for: graph)
        #expect(moved["hub"] == .zero)
        #expect(moved["left"]!.x < original["left"]!.x)
        #expect(moved["right"]!.x > original["right"]!.x)
        #expect(moved["above"]!.y < original["above"]!.y)
        #expect(moved["below"]!.y > original["below"]!.y)
        #expect(moved["distant"] == original["distant"])
        #expect(session.graphNodeSizingLayoutRevision > 0)

        for zoom: CGFloat in [0.005, 0.05, 0.2, 0.42] {
            session.resizeGraphNodesForCurrentMetric(minimumZoom: zoom)
            let frames = tables.map { table -> CGRect in
                let center = session.graphLayout.position(for: table.id)
                let card = GraphCardLayout.nodeSize(title: table.name, descriptor: nil, style: .collapsed)
                let frame = CGRect(x: (center.x - card.width / 2) * zoom,
                                   y: (center.y - card.height / 2) * zoom,
                                   width: card.width * zoom, height: card.height * zoom)
                return GraphHoverPresentation.markerFrame(
                    session.graphNodeSizeProfile.markerFrame(for: table.id, frame: frame, zoom: zoom),
                    hovered: true, connected: false
                )
            }
            for i in frames.indices {
                for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
            }
        }
    }

    @Test(arguments: [12, 30], [400, 620])
    func fittingSettlesMinimumMarkerClearanceBeforeApplyingTheCamera(columns: Int, viewportHeight: Int) {
        let tables = (0..<585).map { index in
            table(String(format: "node_%04d", index), fields: index.isMultiple(of: 3) ? 100 : 1)
        }
        let graph = SchemaGraph(nodes: tables.map { GraphNode(id: $0.id, title: $0.name, isEditable: true) }, edges: [])
        let points = Dictionary(uniqueKeysWithValues: tables.enumerated().map { index, table in
            (table.id, CGPoint(x: (index % columns) * 250, y: (index / columns) * 74))
        })
        let session = AppSession()
        session.graphNodeSizeMetric = .uniform
        session.tables = tables
        session.graph = graph
        session.graphZoom = 1
        session.graphLayout.restore(.init(positions: points, pinnedPositions: [:]), for: graph,
                                    presentation: .compact, descriptorLookup: nil)
        session.setGraphNodeSizeMetric(.fields, persist: false)
        let viewport = CGSize(width: 650, height: viewportHeight)
        let topInset: CGFloat = 68, bottomInset: CGFloat = 100
        var camera = GraphViewportTransform.fit(contentBoundsAtZoom: { proposedZoom in
            session.resizeGraphNodesForCurrentMetric(minimumZoom: proposedZoom)
            return tables.reduce(CGRect.null) { bounds, table in
                let center = session.graphLayout.position(for: table.id)
                let cardSize = GraphCardLayout.nodeSize(title: table.name, descriptor: nil, style: .collapsed)
                let size = session.graphNodeSizeProfile.layoutSize(for: table.id, cardSize: cardSize, minimumZoom: proposedZoom)
                return bounds.union(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                           width: size.width, height: size.height))
            }
        }, initialZoom: 1, in: CGSize(width: viewport.width, height: viewport.height - topInset - bottomInset),
           padding: 36, minZoom: 0.005)
        camera.pan.height += (topInset - bottomInset) / 2
        let fittedPositions = session.graphLayout.allPositions(for: graph)
        session.resizeGraphNodesForCurrentMetric(minimumZoom: camera.zoom)
        #expect(session.graphLayout.allPositions(for: graph) == fittedPositions)
        let visible = CGRect(x: 0, y: topInset, width: viewport.width, height: viewport.height - topInset - bottomInset)
        for table in tables {
            let center = session.graphLayout.position(for: table.id)
            let size = GraphCardLayout.nodeSize(title: table.name, descriptor: nil, style: .collapsed)
            let frame = camera.rect(for: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                                width: size.width, height: size.height), in: viewport)
            let marker = session.graphNodeSizeProfile.markerFrame(for: table.id, frame: frame, zoom: camera.zoom)
            #expect(visible.contains(GraphHoverPresentation.markerFrame(marker, hovered: true, connected: false)))
        }
    }

    @Test func temporaryFocusClearanceAnchorsItsRootAndPreservesTheOverview() throws {
        let tables = [table("hub", fields: 100), table("above", fields: 1), table("below", fields: 1), table("distant", fields: 1)]
        let graph = SchemaGraph(nodes: tables.map { GraphNode(id: $0.id, title: $0.name, isEditable: true) }, edges: [])
        let points = ["hub": CGPoint.zero, "above": CGPoint(x: 0, y: -125),
                      "below": CGPoint(x: 0, y: 125), "distant": CGPoint(x: 3_000, y: 3_000)]
        let session = AppSession()
        session.graphNodeSizeMetric = .uniform
        session.tables = tables
        session.graph = graph
        session.graphZoom = 1
        session.graphLayout.restore(.init(positions: points, pinnedPositions: [:]), for: graph,
                                    presentation: .compact, descriptorLookup: nil)
        session.setGraphNodeSizeMetric(.fields, persist: false)
        let overview = session.graphLayout.snapshot(for: graph)
        let focus = points.filter { $0.key != "distant" }
        session.setExpandedGraphNode("hub")
        let resized = try #require(session.resizeGraphNodesForCurrentMetric(
            minimumZoom: 1,
            nodeSizeLookup: { $0 == "hub" ? CGSize(width: 440, height: 236) : CGSize(width: 226, height: 46) },
            focusPositions: focus, focusAnchorID: "hub"
        ))
        #expect(resized["hub"] == focus["hub"])
        #expect(resized["above"]!.y < focus["above"]!.y)
        #expect(resized["below"]!.y > focus["below"]!.y)
        #expect(session.graphLayout.snapshot(for: graph) == overview)
        // Metadata-triggered overview clearance also ignores temporary expansion.
        session.resizeGraphNodesForCurrentMetric(minimumZoom: 1)
        #expect(session.graphLayout.snapshot(for: graph) == overview)
        session.collapseExpandedGraphNodes()
        #expect(session.graphLayout.snapshot(for: graph) == overview)
    }

    @Test(arguments: [18, 32, 80])
    func fittedMetricFocusKeepsRenderedNeighboursClearOfTheReadableRoot(count: Int) throws {
        let items = (0..<count).map { index in
            GraphFocusRingLayout.Item(id: "related_\(index)", size: CGSize(width: 440, height: index.isMultiple(of: 3) ? 116 : 92))
        }
        let tables = [table("hub", rows: 100)] + items.enumerated().map { index, item in
            table(item.id, rows: index.isMultiple(of: 2) ? 100 : 0)
        }
        let graph = SchemaGraph(nodes: tables.map { GraphNode(id: $0.id, title: $0.name, isEditable: true) }, edges: [])
        let session = AppSession()
        session.graphNodeSizeMetric = .uniform
        session.tables = tables
        session.graph = graph
        session.graphZoom = 1
        let overviewPoints = Dictionary(uniqueKeysWithValues: tables.enumerated().map { index, table in
            (table.id, CGPoint(x: index * 1_000, y: 0))
        })
        session.graphLayout.restore(.init(positions: overviewPoints, pinnedPositions: [:]), for: graph,
                                    presentation: .compact, descriptorLookup: nil)
        session.setGraphNodeSizeMetric(.rows, persist: false)
        let overview = session.graphLayout.snapshot(for: graph)
        let viewport = CGSize(width: 1_000, height: 600)
        let topInset: CGFloat = 78, bottomInset: CGFloat = 70
        let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.size) })
            .merging(["hub": CGSize(width: 440, height: 236)]) { _, root in root }
        var positions = GraphFocusRingLayout.graphPositions(hubCenter: .zero, hubSize: sizes["hub"]!,
                                                            items: items, viewportSize: viewport)
        positions["hub"] = .zero
        var camera = GraphViewportTransform.fit(contentBoundsAtZoom: { proposedZoom in
            positions = session.resizeGraphNodesForCurrentMetric(minimumZoom: proposedZoom,
                nodeSizeLookup: { sizes[$0]! }, focusPositions: positions, focusAnchorID: "hub")!
            return positions.reduce(CGRect.null) { bounds, entry in
                let size = session.graphNodeSizeProfile.layoutSize(for: entry.key, cardSize: sizes[entry.key]!,
                                                                   minimumZoom: proposedZoom, isFocusRoot: entry.key == "hub")
                return bounds.union(CGRect(x: entry.value.x - size.width / 2, y: entry.value.y - size.height / 2,
                                           width: size.width, height: size.height))
            }
        }, initialZoom: 1, in: CGSize(width: viewport.width, height: viewport.height - topInset - bottomInset),
           padding: 24, minZoom: 0.01, maxZoom: 1.3)
        camera.pan.height += (topInset - bottomInset) / 2
        #expect(positions["hub"] == .zero)
        #expect(session.graphLayout.snapshot(for: graph) == overview)
        let frames = Dictionary(uniqueKeysWithValues: positions.map { id, center in
            let size = sizes[id]!
            return (id, camera.rect(for: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                                width: size.width, height: size.height), in: viewport))
        })
        let geometry = GraphInteractionGeometryCache().snapshot(
            frames: frames, viewport: CGRect(origin: .zero, size: viewport), zoom: camera.zoom,
            isLarge: true, emphasized: Set(sizes.keys), primary: ["hub"], contentRevision: 0,
            hoveredID: "hub", connectedIDs: Set(items.map(\.id)), nodeSizing: session.graphNodeSizeProfile,
            focusRootID: "hub", roleForNode: { $0 == "hub" ? .expandedNode : .previewNode }, descriptorForNode: { _ in nil }
        )
        let root = try #require(geometry.anchorMap.nodeCards["hub"]?.frame)
        let visible = CGRect(x: 0, y: topInset, width: viewport.width, height: viewport.height - topInset - bottomInset)
        #expect(visible.contains(root))
        for item in items {
            let neighbour = try #require(geometry.anchorMap.nodeCards[item.id]?.frame)
            #expect(!neighbour.intersects(root))
            #expect(visible.contains(neighbour))
        }
    }

    @Test func renderingHoverAnchorsAndHitTargetsShareSizedMarkerGeometry() throws {
        let tables = [table("a", rows: 0), table("b", rows: 1_000)]
        let frames = ["a": CGRect(x: 50, y: 50, width: 76, height: 9.2), "b": CGRect(x: 150, y: 50, width: 76, height: 9.2)]
        let profile = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: [:], relationCounts: [:])
        let cache = GraphInteractionGeometryCache()
        func snapshot(_ profile: GraphNodeSizeProfile, hovered: String? = nil) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
                           zoom: 0.2, isLarge: true, emphasized: [], contentRevision: 0, hoveredID: hovered,
                           nodeSizing: profile, roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil })
        }
        let original = snapshot(.uniform)
        let sized = snapshot(profile)
        #expect(sized.revision != original.revision)
        #expect(sized.frames == original.frames)
        let mark = try #require(sized.markerFrames["a"])
        #expect(sized.anchorMap.nodeCards["a"]?.frame == mark)
        #expect(sized.hitCandidates(at: CGPoint(x: mark.midX, y: mark.midY)) == ["a"])
        #expect(sized.hitCandidates(at: CGPoint(x: 51, y: 51)).isEmpty)
        #expect(snapshot(profile).revision == sized.revision)
        let hovered = snapshot(profile, hovered: "a")
        let enlarged = try #require(hovered.markerFrames["a"])
        #expect(enlarged.width > mark.width)
        #expect(hovered.hitCandidates(at: CGPoint(x: enlarged.minX + 0.1, y: enlarged.midY)) == ["a"])
        let detail = cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
                                    zoom: 1, isLarge: false, emphasized: [], contentRevision: 0, nodeSizing: profile,
                                    roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil })
        #expect(detail.markerFrames.isEmpty)
        #expect(detail.anchorMap.nodeCards["a"]?.frame == frames["a"])
    }

    @Test func temporarySizingDoesNotPersistWithoutSourceAndInvalidLegacyValueFallsBackToUniform() throws {
        let suite = "GraphNodeSizingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        #expect(session.graphNodeSizeMetric == .uniform)
        session.graphNodeSizeMetric = .fields
        let restored = AppSession(userDefaults: defaults)
        #expect(restored.graphNodeSizeMetric == .uniform)
        restored.graphNodeSizeMetric = .fields
        restored.tables = [table("a", fields: 5), table("b", fields: 10)]
        #expect(restored.graphNodeSizeProfile.areas["a"]! < restored.graphNodeSizeProfile.areas["b"]!)
        defaults.set("invalid", forKey: "SQLiteGraphStudio.graph-node-size-metric")
        #expect(AppSession(userDefaults: defaults).graphNodeSizeMetric == .uniform)
    }

    @Test func filteringPreservesFullSchemaScaleAndClosingClearsOldCounts() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in
            try db.execute(sql: """
                CREATE TABLE parent(a INTEGER, b INTEGER, PRIMARY KEY(a,b));
                CREATE TABLE child(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, parent_id INTEGER REFERENCES child(id),
                                   FOREIGN KEY(a,b) REFERENCES parent(a,b));
                CREATE TABLE isolated(id INTEGER PRIMARY KEY);
                INSERT INTO parent VALUES(1,1);
                INSERT INTO child VALUES(1,1,1,NULL);
                """)
        }
        try database.close()
        let suite = "GraphNodeSizingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        #expect(session.presentedError == nil)
        session.setGraphNodeSizeMetric(.relations, persist: true)
        #expect(session.graphRelationCounts == ["parent": 1, "child": 2])
        let original = session.graphNodeSizeProfile
        #expect(await session.applyGraphFilter(.init(maximumRelations: 1)))
        #expect(session.graphVisibleTableIDs == ["parent", "isolated"])
        #expect(session.graphNodeSizeProfile == original)
        session.clearGraphFilter()
        #expect(session.graphNodeSizeProfile == original)
        session.graphNodeSizeMetric = .rows
        #expect(await session.applyGraphFilter(.init(maximumRows: 0)))
        #expect(session.graphVisibleTableIDs == ["isolated"])
        #expect(session.graphNodeSizeProfile.areas["isolated"] == 0.12)
        #expect(session.graphNodeSizeProfile.areas["child"] == 1)
        await session.closeAndWait()
        #expect(session.graphNodeSizeProfile.areas.isEmpty)
        #expect(session.graphNodeSizeProfile.unknownIDs.isEmpty)
        #expect(session.graphNodeSizeMetric == .rows)
        let restored = AppSession(userDefaults: defaults)
        await restored.openDatabase(url: url)
        #expect(restored.graphNodeSizeMetric == .relations)
        await restored.closeAndWait()
    }
}
