import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// Measures CPU preparation and lookup work, not SwiftUI drawing or frame rate.
/// Run alone with `swift test -c release --filter GraphCanvasPerformanceTests`.
/// Timing observations have no machine-dependent pass threshold; correctness and
/// work bounds are asserted independently of the measured intervals.
/// Pan/zoom uses cached world bounds; the hover scenario regenerates them with
/// the real card-sizing function and reports that cost separately.
@Suite(.serialized)
@MainActor
struct GraphCanvasPerformanceTests {
    @Test(arguments: [581, 2_000])
    func repeatedPanAndZoomKeepTopologyAndDetailWorkBounded(nodeCount: Int) {
        let fixture = CanvasPerformanceFixture(nodeCount: nodeCount)
        let topologyCache = GraphTopologyCache()
        let topologyStarted = ContinuousClock.now
        let topology = topologyCache.index(for: fixture.graph, graphRevision: 1)
        let topologyMicroseconds = microseconds(since: topologyStarted)
        let links = topologyCache.groupLinks(for: fixture.graph, graphRevision: 1,
                                            membership: fixture.membership, groupingRevision: 1)
        let linksRevision = topologyCache.groupLinksRevision
        #expect(!links.isEmpty)
        #expect(fixture.graph.edges.count > nodeCount * 3)

        for expanded in [false, true] {
            let geometryCache = GraphInteractionGeometryCache()
            let worldFrames = fixture.worldFrames(expanded: expanded)
            let fit = GraphViewportTransform.fit(contentBounds: worldFrames.values.reduce(CGRect.null) { $0.union($1) },
                                                  in: viewport.size, padding: 160, minZoom: 0.001, maxZoom: 0.3)
            for scenario in CanvasPerformanceScenario.allCases {
                var preparationTimes: [Double] = []
                var reuseTimes: [Double] = []
                var worldFrameTimes: [Double] = []
                var screenPreparationTimes: [Double] = []
                var hoverHitTimes: [Double] = []
                var maximumDetails = 0
                var maximumRows = 0
                var descriptorReads = 0
                var roleReads = 0
                let emphasized = scenario == .selectionOverview ? Set(fixture.ids) : Set<String>()
                let selectionPrimary: Set<String> = scenario == .selectionOverview ? [fixture.ids[0]] : []

                for sample in 0..<40 {
                    let transform = fixture.transform(sample: sample, scenario: scenario, fit: fit)
                    let hoveredID = scenario == .hoveredWorldFrames ? fixture.ids[(sample * 97) % nodeCount] : nil
                    let primary: Set<String> = hoveredID.map { Set([$0]) } ?? selectionPrimary
                    let readsBeforePreparation = descriptorReads
                    let started = ContinuousClock.now
                    let index = topologyCache.index(for: fixture.graph, graphRevision: 1)
                    let currentLinks = topologyCache.groupLinks(for: fixture.graph, graphRevision: 1,
                                                               membership: fixture.membership, groupingRevision: 1)
                    var currentWorldFrames = worldFrames
                    var worldFrameTime = 0.0
                    if let hoveredID {
                        let worldStarted = ContinuousClock.now
                        currentWorldFrames = fixture.worldFrames(expanded: expanded, hoveredID: hoveredID)
                        worldFrameTime = microseconds(since: worldStarted)
                    }
                    let screenStarted = ContinuousClock.now
                    let frames = GraphInteractionGeometry.screenFrames(worldFrames: currentWorldFrames, transform: transform,
                                                                       viewportSize: viewport.size)
                    let snapshot = geometryCache.snapshot(
                        frames: frames, viewport: viewport, zoom: transform.zoom, isLarge: true,
                        emphasized: emphasized, primary: primary, contentRevision: expanded ? 2 : 1,
                        roleForNode: { _ in roleReads += 1; return expanded ? .expandedNode : .collapsedNode },
                        descriptorForNode: { id in descriptorReads += 1; return fixture.descriptors[id] }
                    )
                    let screenPreparation = microseconds(since: screenStarted)
                    let preparation = microseconds(since: started)
                    var hoverHitTime = 0.0
                    if let hoveredID {
                        let point = transform.point(for: fixture.positions[hoveredID]!, in: viewport.size)
                        let hitStarted = ContinuousClock.now
                        let hits = snapshot.hitCandidates(at: point)
                        hoverHitTime = microseconds(since: hitStarted)
                        #expect(hits.contains(hoveredID))
                        #expect(snapshot.renderPlan.detailIDs.contains(hoveredID))
                    }
                    let readsBeforeReuse = descriptorReads
                    let rolesBeforeReuse = roleReads
                    let reuseStarted = ContinuousClock.now
                    let reused = geometryCache.snapshot(
                        frames: frames, viewport: viewport, zoom: transform.zoom, isLarge: true,
                        emphasized: emphasized, primary: primary, contentRevision: expanded ? 2 : 1,
                        roleForNode: { _ in roleReads += 1; return expanded ? .expandedNode : .collapsedNode },
                        descriptorForNode: { id in descriptorReads += 1; return fixture.descriptors[id] }
                    )
                    let reuse = microseconds(since: reuseStarted)

                    #expect(index === topology)
                    #expect(currentLinks == links)
                    #expect(topologyCache.groupLinksRevision == linksRevision)
                    #expect(snapshot.anchorMap.nodeCards.count == nodeCount)
                    #expect(snapshot.renderPlan.detailIDs.count <= GraphExploration.maximumDetailedCards)
                    #expect(descriptorReads - readsBeforePreparation <= GraphExploration.maximumDetailedCards)
                    #expect(reused.revision == snapshot.revision)
                    #expect(descriptorReads == readsBeforeReuse)
                    #expect(roleReads == rolesBeforeReuse)
                    let rowCount = snapshot.anchorMap.nodeCards.values.reduce(0) { $0 + $1.rowFrames.count }
                    #expect(rowCount <= GraphExploration.maximumDetailedCards * GraphCardLayout.maxExpandedVisibleRows)
                    #expect(snapshot.renderPlan.markerIDs.allSatisfy {
                        snapshot.anchorMap.nodeCards[$0]?.rowFrames.isEmpty == true
                    })
                    if scenario == .selectionOverview {
                        #expect(snapshot.renderPlan.detailIDs.count == GraphExploration.maximumDetailedCards)
                        #expect(snapshot.renderPlan.detailIDs.contains(fixture.ids[0]))
                        #expect(snapshot.renderPlan.interactiveIDs.count == nodeCount)
                    }
                    maximumDetails = max(maximumDetails, snapshot.renderPlan.detailIDs.count)
                    maximumRows = max(maximumRows, rowCount)
                    if sample >= 8 {
                        preparationTimes.append(preparation)
                        reuseTimes.append(reuse)
                        if hoveredID != nil {
                            worldFrameTimes.append(worldFrameTime)
                            screenPreparationTimes.append(screenPreparation)
                            hoverHitTimes.append(hoverHitTime)
                        }
                    }
                }
                if !expanded { #expect(descriptorReads == 0) }
                var metrics: [String: Any] = [
                    "measurement": "canvas_preparation", "tables": nodeCount, "edges": fixture.graph.edges.count,
                    "presentation": expanded ? "all_cards" : "compact", "scenario": scenario.rawValue,
                    "samples": preparationTimes.count, "prepare_p50_us": percentile(preparationTimes, 0.5),
                    "prepare_p95_us": percentile(preparationTimes, 0.95), "reuse_p50_us": percentile(reuseTimes, 0.5),
                    "reuse_p95_us": percentile(reuseTimes, 0.95), "max_detailed_cards": maximumDetails,
                    "max_row_frames": maximumRows, "topology_build_us": topologyMicroseconds,
                    "topology_instances": 1, "group_link_builds": topologyCache.groupLinksRevision
                ]
                if scenario == .hoveredWorldFrames {
                    metrics["world_frames_p50_us"] = percentile(worldFrameTimes, 0.5)
                    metrics["world_frames_p95_us"] = percentile(worldFrameTimes, 0.95)
                    metrics["screen_prepare_p50_us"] = percentile(screenPreparationTimes, 0.5)
                    metrics["screen_prepare_p95_us"] = percentile(screenPreparationTimes, 0.95)
                    metrics["hover_hit_p50_us"] = percentile(hoverHitTimes, 0.5)
                    metrics["hover_hit_p95_us"] = percentile(hoverHitTimes, 0.95)
                }
                report(metrics)
            }
        }
    }

    @Test(arguments: [581, 2_000])
    func pointerIndexAndPublisherPreserveHitsWhileCoalescingBursts(nodeCount: Int) async throws {
        let fixture = CanvasPerformanceFixture(nodeCount: nodeCount)
        let cache = GraphInteractionGeometryCache()
        let worldFrames = fixture.worldFrames(expanded: true)
        let fit = GraphViewportTransform.fit(contentBounds: worldFrames.values.reduce(CGRect.null) { $0.union($1) },
                                              in: viewport.size, padding: 160, minZoom: 0.001, maxZoom: 0.3)
        let frames = GraphInteractionGeometry.screenFrames(worldFrames: worldFrames, transform: fit, viewportSize: viewport.size)
        let snapshot = cache.snapshot(frames: frames, viewport: viewport, zoom: fit.zoom, isLarge: true,
                                      emphasized: Set(fixture.ids), contentRevision: 1,
                                      roleForNode: { _ in .expandedNode }, descriptorForNode: { fixture.descriptors[$0] })
        let hitFrames = Dictionary(uniqueKeysWithValues: snapshot.renderPlan.interactiveIDs.map { id in
            (id, snapshot.renderPlan.markerIDs.contains(id) ? GraphExploration.markerFrame(for: frames[id]!) : frames[id]!)
        })
        var points = (0..<192).map { sample in
            CGPoint(x: CGFloat((sample * 127) % Int(viewport.width)), y: CGFloat((sample * 83) % Int(viewport.height)))
        }
        points += stride(from: 0, to: nodeCount, by: max(1, nodeCount / 96)).map { index in
            let frame = frames[fixture.ids[index]]!
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        points += [CGPoint(x: -500, y: -500), CGPoint(x: 5_000, y: 5_000)]
        let expected = points.map { point in
            Set(hitFrames.compactMap { id, frame in frame.contains(point) ? id : nil })
        }
        for (point, hits) in zip(points, expected) {
            #expect(Set(snapshot.hitCandidates(at: point)) == hits)
        }

        var pointerTimes: [Double] = []
        var deliveredQueries = 0
        var hitChecksum = 0
        for batch in 0..<40 {
            let started = ContinuousClock.now
            for point in points { hitChecksum += snapshot.hitCandidates(at: point).count }
            let perQuery = microseconds(since: started) / Double(points.count)
            if batch >= 8 { pointerTimes.append(perQuery) }
        }
        #expect(hitChecksum > 0)

        let publisher = GraphInputPublisher<GraphPointerSample>(interval: .milliseconds(4))
        var delivered: [GraphPointerSample] = []
        var publicationTimes: [Double] = []
        var enqueuedSamples = 0
        let receive: @MainActor (GraphPointerSample) -> Void = { sample in
            let started = ContinuousClock.now
            if let point = sample.point { hitChecksum += snapshot.hitCandidates(at: point).count }
            publicationTimes.append(microseconds(since: started))
            deliveredQueries += 1
            delivered.append(sample)
        }
        for burst in 0..<12 {
            let expectedCount = delivered.count + 1
            let finalPoint = points[(burst * 17 + 63) % points.count]
            for sample in 0..<64 {
                publisher.enqueue(GraphPointerSample(point: points[(burst * 17 + sample) % points.count],
                                                     geometryRevision: snapshot.revision), publish: receive)
                enqueuedSamples += 1
            }
            // No suspension occurs inside the burst, so only its newest sample can publish.
            #expect(delivered.count == expectedCount - 1)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while delivered.count < expectedCount, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(delivered.count == expectedCount)
            #expect(delivered.last == GraphPointerSample(point: finalPoint, geometryRevision: snapshot.revision))
        }
        #expect(deliveredQueries == 12)
        let latest = try #require(delivered.last)
        publisher.flush(latest, publish: receive)
        #expect(deliveredQueries == 12)
        let geometryChanged = GraphPointerSample(point: latest.point, geometryRevision: snapshot.revision + 1)
        publisher.flush(geometryChanged, publish: receive)
        #expect(delivered.last == geometryChanged)
        #expect(deliveredQueries == 13)
        publisher.enqueue(GraphPointerSample(point: nil, geometryRevision: snapshot.revision + 1), publish: receive)
        publisher.cancel()
        try await Task.sleep(for: .milliseconds(16))
        #expect(deliveredQueries == 13)

        report([
            "measurement": "pointer_lookup_and_publication", "tables": nodeCount, "edges": fixture.graph.edges.count,
            "query_points": points.count, "query_batches": pointerTimes.count,
            "batch_mean_query_p50_us": percentile(pointerTimes, 0.5), "batch_mean_query_p95_us": percentile(pointerTimes, 0.95),
            "matching_candidates_p95": percentile(expected.map { Double($0.count) }, 0.95),
            "matching_candidates_max": expected.map(\.count).max() ?? 0,
            "enqueued_samples": enqueuedSamples, "burst_publications": 12,
            "publication_callback_p50_us": percentile(publicationTimes, 0.5),
            "publication_callback_p95_us": percentile(publicationTimes, 0.95), "hit_checksum": hitChecksum
        ])
    }

    private var viewport: CGRect { CGRect(x: 0, y: 0, width: 1_200, height: 800) }
}

private enum CanvasPerformanceScenario: String, CaseIterable {
    case overview, detailPanZoom, selectionOverview, hoveredWorldFrames
}

/// Qualified names, 12–36 columns, views, local chains, hub references and
/// cross-group edges make cache work representative without invoking the layout solver.
private struct CanvasPerformanceFixture {
    let graph: SchemaGraph
    let ids: [String]
    let descriptors: [String: EditableTableDescriptor]
    let membership: [String: String]
    let positions: [String: CGPoint]

    init(nodeCount: Int) {
        let schemas = ["public", "audit", "identity", "reporting"]
        let names = (0..<nodeCount).map { index in
            "\(schemas[(index / 48) % schemas.count]).\(index.isMultiple(of: 19) ? "workspace_activity_summary" : "business_record")_\(index)"
        }
        var descriptors: [String: EditableTableDescriptor] = [:]
        var membership: [String: String] = [:]
        var positions: [String: CGPoint] = [:]
        var edges: [GraphEdge] = []
        let groupColumns = max(1, Int(ceil(sqrt(Double((nodeCount + 47) / 48) * 1.8))))
        for index in 0..<nodeCount {
            let id = names[index], group = index / 48, local = index % 48
            let columns = (0..<(12 + index % 25)).map { column in
                TableColumn(name: column == 0 ? "id" : "field_\(column)",
                            declaredType: column == 0 ? "uuid" : (column % 3 == 0 ? "jsonb" : "text"),
                            notNull: column < 3, defaultValueSQL: nil, primaryKeyOrdinal: column == 0 ? 1 : 0,
                            hiddenValue: 0, isEditable: false)
            }
            descriptors[id] = EditableTableDescriptor(
                name: id, objectType: index.isMultiple(of: 19) ? .view : .table,
                columns: columns, primaryKeyColumns: ["id"], rowIdentityStrategy: .readOnly,
                isWithoutRowID: false, isEditable: false, schemaName: schemas[group % schemas.count]
            )
            membership[id] = "group_\(group)"
            positions[id] = CGPoint(x: (group % groupColumns) * 2_650 + (local % 6) * 400,
                                    y: (group / groupColumns) * 2_350 + (local / 6) * 270)
            for (offset, target) in [max(0, index - 1), group * 48, (index + 73) % nodeCount, (index + 157) % nodeCount].enumerated() where target != index {
                edges.append(GraphEdge(id: "edge_\(index)_\(offset)", sourceID: id, targetID: names[target],
                                       sourceColumn: "field_\(offset + 1)", targetColumn: "id"))
            }
        }
        self.ids = names
        self.graph = SchemaGraph(nodes: names.map { GraphNode(id: $0, title: $0, isEditable: false) }, edges: edges)
        self.descriptors = descriptors
        self.membership = membership
        self.positions = positions
    }

    func worldFrames(expanded: Bool, hoveredID: String? = nil) -> [String: CGRect] {
        GraphInteractionGeometry.worldFrames(nodeIDs: ids, positionForNode: { positions[$0]! }, sizeForNode: { id in
            GraphCardLayout.nodeSize(title: id, descriptor: descriptors[id], style: expanded ? .expanded : .collapsed,
                                     hovered: id == hoveredID)
        })
    }

    func transform(sample: Int, scenario: CanvasPerformanceScenario, fit: GraphViewportTransform) -> GraphViewportTransform {
        let phase = CGFloat(sample) * 0.23
        if scenario == .detailPanZoom || scenario == .hoveredWorldFrames {
            let positionStride = scenario == .hoveredWorldFrames ? 97 : 7
            let point = positions[ids[(sample * positionStride) % ids.count]]!
            let zoom = 0.62 + 0.12 * sin(phase)
            return GraphViewportTransform(zoom: zoom, pan: CGSize(width: -point.x * zoom + 45 * sin(phase),
                                                                 height: -point.y * zoom + 30 * cos(phase)))
        }
        return GraphViewportTransform(zoom: fit.zoom, pan: CGSize(width: fit.pan.width + 24 * sin(phase),
                                                                height: fit.pan.height + 18 * cos(phase)))
    }
}

private func microseconds(since started: ContinuousClock.Instant) -> Double {
    let components = started.duration(to: .now).components
    return Double(components.seconds) * 1_000_000 + Double(components.attoseconds) / 1_000_000_000_000
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
}

private func report(_ metrics: [String: Any]) {
    var metrics = metrics
    #if DEBUG
    metrics["configuration"] = "debug"
    #else
    metrics["configuration"] = "release"
    #endif
    if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        print("GRAPH_CANVAS_PERF \(json)")
    }
}
