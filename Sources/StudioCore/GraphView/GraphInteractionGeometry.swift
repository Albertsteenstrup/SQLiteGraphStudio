import CoreGraphics
import Foundation

/// Immutable lookup built when topology changes, rather than sorting every relation
/// during a pointer or camera update. Table IDs remain canonical for both backends.
final class GraphTopologyIndex: Sendable {
    private let outgoingByTable: [String: [GraphEdge]]
    private let incomingByTable: [String: [GraphEdge]]
    private let nodeIndices: [String: Int]

    init(graph: SchemaGraph) {
        outgoingByTable = Dictionary(grouping: graph.edges, by: \.sourceID).mapValues { edges in
            edges.sorted { lhs, rhs in
                let columnOrder = lhs.sourceColumn.localizedStandardCompare(rhs.sourceColumn)
                if columnOrder != .orderedSame { return columnOrder == .orderedAscending }
                let targetOrder = lhs.targetID.localizedStandardCompare(rhs.targetID)
                if targetOrder != .orderedSame { return targetOrder == .orderedAscending }
                return (lhs.sourceColumn, lhs.targetID, lhs.targetColumn, lhs.id)
                    < (rhs.sourceColumn, rhs.targetID, rhs.targetColumn, rhs.id)
            }
        }
        incomingByTable = Dictionary(grouping: graph.edges, by: \.targetID).mapValues { edges in
            edges.sorted { lhs, rhs in
                let sourceOrder = lhs.sourceID.localizedStandardCompare(rhs.sourceID)
                if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
                let columnOrder = lhs.sourceColumn.localizedStandardCompare(rhs.sourceColumn)
                if columnOrder != .orderedSame { return columnOrder == .orderedAscending }
                return (lhs.sourceID, lhs.sourceColumn, lhs.targetColumn, lhs.id)
                    < (rhs.sourceID, rhs.sourceColumn, rhs.targetColumn, rhs.id)
            }
        }
        nodeIndices = Dictionary(graph.nodes.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
    }

    func outgoingEdges(for tableID: String) -> [GraphEdge] { outgoingByTable[tableID, default: []] }
    func incomingEdges(for tableID: String) -> [GraphEdge] { incomingByTable[tableID, default: []] }
    func nodeIndex(for tableID: String) -> Int? { nodeIndices[tableID] }
}

/// Revisions are advanced by the graph owner on assignment. Cache hits compare only
/// integers; they never hash or compare the full graph or grouping dictionaries.
@MainActor
final class GraphTopologyCache {
    private var graphRevision: Int?
    private var cachedIndex: GraphTopologyIndex?
    private var groupingRevision: Int?
    private var cachedGroupLinks: [GraphExploration.GroupLink] = []
    private(set) var groupLinksRevision = 0

    func index(for graph: SchemaGraph, graphRevision revision: Int) -> GraphTopologyIndex {
        if graphRevision == revision, let cachedIndex { return cachedIndex }
        let index = GraphTopologyIndex(graph: graph)
        graphRevision = revision
        cachedIndex = index
        groupingRevision = nil
        cachedGroupLinks = []
        return index
    }

    func groupLinks(
        for graph: SchemaGraph,
        graphRevision: Int,
        membership: [String: String],
        groupingRevision revision: Int
    ) -> [GraphExploration.GroupLink] {
        _ = index(for: graph, graphRevision: graphRevision)
        guard groupingRevision != revision else { return cachedGroupLinks }
        cachedGroupLinks = GraphExploration.groupLinks(edges: graph.edges, membership: membership)
        groupingRevision = revision
        groupLinksRevision &+= 1
        return cachedGroupLinks
    }
}

/// Screen bounds and one shared rendering/hit-testing decision. All scoped tables
/// retain cheap rectangles for crossing-edge anchors; only detailed cards have rows.
struct GraphInteractionGeometry {
    let frames: [String: CGRect]
    let renderPlan: GraphExploration.RenderPlan
    let anchorMap: GraphAnchorMap
    let revision: Int
    fileprivate let hitIndex: GraphInteractionHitIndex

    /// The caller resolves overlapping candidates by visual z-index and graph order.
    /// Offscreen, scope-hidden tables are absent; markers use their rendered 3px floor.
    func hitCandidates(at point: CGPoint) -> [String] { hitIndex.candidates(at: point) }

    /// Detail cards are a layer above Canvas markers. Resolve within that layer
    /// using the same z-index and original node order as the SwiftUI card views.
    func topmostHit(at point: CGPoint, zIndexForNode: (String) -> Double,
                    nodeIndexForNode: (String) -> Int?) -> String? {
        var best: (id: String, detail: Bool, z: Double, index: Int)?
        for id in hitCandidates(at: point) {
            guard let index = nodeIndexForNode(id) else { continue }
            let candidate = (id: id, detail: renderPlan.detailIDs.contains(id), z: zIndexForNode(id), index: index)
            if let current = best {
                if candidate.detail != current.detail {
                    if candidate.detail { best = candidate }
                } else if candidate.z > current.z || (candidate.z == current.z && candidate.index > current.index) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best?.id
    }

    static func worldFrames(
        nodeIDs: [String],
        positionForNode: (String) -> CGPoint,
        sizeForNode: (String) -> CGSize
    ) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(nodeIDs.count)
        for id in nodeIDs where frames[id] == nil {
            let center = positionForNode(id)
            let size = sizeForNode(id)
            frames[id] = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        return frames
    }

    static func screenFrames(
        worldFrames: [String: CGRect],
        transform: GraphViewportTransform,
        viewportSize: CGSize
    ) -> [String: CGRect] {
        worldFrames.mapValues { transform.rect(for: $0, in: viewportSize) }
    }
}

@MainActor
final class GraphInteractionGeometryCache {
    private struct Key: Equatable {
        let frames: [String: CGRect]
        let viewport: CGRect
        let zoom: CGFloat
        let isLarge: Bool
        let emphasized: Set<String>
        let primary: Set<String>
        let retained: Set<String>
        let contentRevision: Int
    }

    private var key: Key?
    private var geometry: GraphInteractionGeometry?
    private var revision = 0

    /// `frames` must be cheap bounds already limited to the current focus scope.
    /// `contentRevision` covers row content, display roles and card scroll offsets.
    /// Descriptor/column closures are called only for detailed, non-collapsed cards.
    func snapshot(
        frames: [String: CGRect],
        viewport: CGRect,
        zoom: CGFloat,
        isLarge: Bool,
        emphasized: Set<String>,
        primary: Set<String> = [],
        retained: Set<String> = [],
        contentRevision: Int,
        roleForNode: (String) -> GraphCardRole,
        descriptorForNode: (String) -> EditableTableDescriptor?,
        displayedColumnsForNode: (String) -> [String]? = { _ in nil }
    ) -> GraphInteractionGeometry {
        let newKey = Key(
            frames: frames, viewport: viewport, zoom: zoom, isLarge: isLarge,
            emphasized: emphasized, primary: primary, retained: retained, contentRevision: contentRevision
        )
        if key == newKey, let geometry { return geometry }

        let renderPlan = GraphExploration.renderPlan(
            frames: frames, viewport: viewport, zoom: zoom, isLarge: isLarge,
            emphasized: emphasized, primary: primary, retained: retained
        )
        var nodeCards: [String: GraphCardGeometry] = [:]
        nodeCards.reserveCapacity(frames.count)
        for (id, frame) in frames {
            nodeCards[id] = GraphCardGeometry(tableID: id, frame: frame, role: .collapsedNode, descriptor: nil)
        }
        for id in renderPlan.detailIDs {
            guard let frame = frames[id] else { continue }
            let role = roleForNode(id)
            guard role != .collapsedNode else { continue }
            nodeCards[id] = GraphCardGeometry(
                tableID: id, frame: frame, role: role,
                descriptor: descriptorForNode(id), displayedColumns: displayedColumnsForNode(id), scale: zoom
            )
        }

        let interactiveFrames = Dictionary(uniqueKeysWithValues: renderPlan.interactiveIDs.compactMap { id in
            frames[id].map { frame in
                (id, renderPlan.markerIDs.contains(id) ? GraphExploration.markerFrame(for: frame) : frame)
            }
        })
        revision &+= 1
        let snapshot = GraphInteractionGeometry(
            frames: frames, renderPlan: renderPlan, anchorMap: GraphAnchorMap(nodeCards: nodeCards),
            revision: revision, hitIndex: GraphInteractionHitIndex(frames: interactiveFrames)
        )
        key = newKey
        geometry = snapshot
        return snapshot
    }
}

/// A uniform screen grid bounds routine pointer queries without allocating cells for
/// enormous cards. Large rectangles use a separate fallback list, still tested exactly.
fileprivate struct GraphInteractionHitIndex {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private static let cellSize: CGFloat = 128
    private static let maximumCellsPerFrame = 64
    private let frames: [String: CGRect]
    private let cells: [Cell: [String]]
    private let oversizedIDs: [String]

    init(frames: [String: CGRect]) {
        self.frames = frames
        var cells: [Cell: [String]] = [:]
        var oversized: [String] = []
        for (id, frame) in frames {
            guard let lower = Self.cell(at: CGPoint(x: frame.minX, y: frame.minY)),
                  let upper = Self.cell(at: CGPoint(x: frame.maxX, y: frame.maxY))
            else {
                oversized.append(id)
                continue
            }
            let (xSpan, xOverflow) = upper.x.subtractingReportingOverflow(lower.x)
            let (ySpan, yOverflow) = upper.y.subtractingReportingOverflow(lower.y)
            guard !xOverflow, !yOverflow,
                  xSpan >= 0, ySpan >= 0,
                  xSpan < Self.maximumCellsPerFrame, ySpan < Self.maximumCellsPerFrame,
                  (xSpan + 1) * (ySpan + 1) <= Self.maximumCellsPerFrame
            else {
                oversized.append(id)
                continue
            }
            for x in lower.x...upper.x {
                for y in lower.y...upper.y {
                    cells[Cell(x: x, y: y), default: []].append(id)
                }
            }
        }
        self.cells = cells
        self.oversizedIDs = oversized
    }

    func candidates(at point: CGPoint) -> [String] {
        let local = Self.cell(at: point).map { cells[$0, default: []] } ?? []
        return (local + oversizedIDs).filter { frames[$0]?.contains(point) == true }.sorted()
    }

    private static func cell(at point: CGPoint) -> Cell? {
        let x = floor(point.x / cellSize), y = floor(point.y / cellSize)
        guard x.isFinite, y.isFinite,
              x > CGFloat(Int.min), x < CGFloat(Int.max), y > CGFloat(Int.min), y < CGFloat(Int.max)
        else { return nil }
        return Cell(x: Int(x), y: Int(y))
    }
}
