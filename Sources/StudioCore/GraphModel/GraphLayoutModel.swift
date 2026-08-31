import CoreGraphics
import Foundation

public struct GraphLayoutSnapshot: Sendable, Equatable {
    public let positions: [String: CGPoint]
    public let pinnedPositions: [String: CGPoint]

    public init(positions: [String: CGPoint], pinnedPositions: [String: CGPoint]) {
        self.positions = positions
        self.pinnedPositions = pinnedPositions
    }
}

@MainActor
public final class GraphLayoutModel {
    /// Threshold used by the crowded-schema heuristics that keep ordinary layouts from
    /// being squeezed into a small viewport or from collapsing isolated nodes together.
    public static let crowdedNodeThreshold = 14

    /// Force-directed physics and pairwise overlap cleanup are quadratic in the node
    /// count. Large database schemas use a bounded deterministic overview instead of
    /// physics, which can become numerically unstable when thousands of edge-path forces
    /// accumulate in a single pass.
    public static let largeGraphOverviewThreshold = 128

    private var positions: [String: CGPoint] = [:]
    private var velocities: [String: CGVector] = [:]
    private var pinnedPositions: [String: CGPoint] = [:]
    private var clusterHintByNode: [String: String] = [:]
    private var latestGraphSignature: Int = 0
    private var layoutSeedOffset: UInt64 = 0
    private var settledSteps = 0
    private var tickCount = 0
    private var latestPresentationMode: GraphPresentationMode = .compact

    public private(set) var isAnimating = false
    public private(set) var hasRestoredSnapshot = false
    public private(set) var hasSettledLayout = false

    public init() {}

    /// Set AI-authored cluster hints. Empty dictionary clears any prior hints.
    /// The next layout pass picks them up; call `relayout(...)` if positions are already settled.
    public func setClusterHints(_ hints: [String: String]) {
        clusterHintByNode = hints
        // Force the next reset to re-run, even if the graph hash matches.
        latestGraphSignature = 0
    }

    public func reset(for graph: SchemaGraph) {
        reset(for: graph, presentation: .compact, descriptorLookup: nil)
    }

    func reset(
        for graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?
    ) {
        let signature = graph.hashValue
        guard signature != latestGraphSignature || presentation != latestPresentationMode else { return }

        latestGraphSignature = signature
        latestPresentationMode = presentation
        generateInitialPositions(for: graph, presentation: presentation, descriptorLookup: descriptorLookup)
    }

    public func relayout(for graph: SchemaGraph) {
        relayout(for: graph, presentation: .compact, descriptorLookup: nil)
    }

    func relayout(
        for graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?
    ) {
        layoutSeedOffset &+= 1
        latestGraphSignature = graph.hashValue
        latestPresentationMode = presentation
        generateInitialPositions(for: graph, presentation: presentation, descriptorLookup: descriptorLookup)
    }

    func relayoutPreservingCurrentPositions(
        for graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?
    ) {
        let currentPositions = positions
        layoutSeedOffset &+= 1
        latestGraphSignature = graph.hashValue
        latestPresentationMode = presentation
        generateInitialPositions(for: graph, presentation: presentation, descriptorLookup: descriptorLookup)

        for node in graph.nodes {
            if let position = currentPositions[node.id] {
                positions[node.id] = position
            }
            velocities[node.id] = .zero
        }

        pinnedPositions.removeAll()
        settledSteps = 0
        tickCount = 0
        isAnimating = !graph.nodes.isEmpty
    }

    public func allPositions(for graph: SchemaGraph) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, position(for: $0.id)) })
    }

    public func clearPinnedState() {
        pinnedPositions.removeAll()
    }

    public func snapshot(for graph: SchemaGraph) -> GraphLayoutSnapshot {
        let validIDs = Set(graph.nodes.map(\.id))
        let persistedPositions = positions.filter { validIDs.contains($0.key) }
        let persistedPinnedPositions = pinnedPositions.filter { validIDs.contains($0.key) }
        return GraphLayoutSnapshot(
            positions: persistedPositions,
            pinnedPositions: persistedPinnedPositions
        )
    }

    func restore(
        _ snapshot: GraphLayoutSnapshot,
        for graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?
    ) {
        generateInitialPositions(for: graph, presentation: presentation, descriptorLookup: descriptorLookup)

        for (nodeID, point) in snapshot.positions where positions[nodeID] != nil {
            positions[nodeID] = point
        }

        pinnedPositions = snapshot.pinnedPositions.filter { positions[$0.key] != nil }
        velocities = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, .zero) })
        latestGraphSignature = graph.hashValue
        latestPresentationMode = presentation
        settledSteps = 0
        tickCount = 0
        isAnimating = false
        hasRestoredSnapshot = true
        hasSettledLayout = true
    }

    func stabilize(
        graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?,
        nodeSizeLookup: ((String) -> CGSize)?,
        maxIterations: Int = 220
    ) {
        guard !graph.nodes.isEmpty else {
            isAnimating = false
            return
        }

        isAnimating = true
        settledSteps = 0

        let boundedMaxIterations: Int
        if graph.nodes.count > Self.largeGraphOverviewThreshold {
            boundedMaxIterations = 0
        } else {
            boundedMaxIterations = maxIterations
        }

        for _ in 0..<boundedMaxIterations where isAnimating {
            step(
                graph: graph,
                presentation: presentation,
                descriptorLookup: descriptorLookup,
                nodeSizeLookup: nodeSizeLookup
            )
        }

        let overlapIterations = graph.nodes.count > Self.largeGraphOverviewThreshold ? 0 : 80

        resolveRemainingOverlaps(
            graph: graph,
            presentation: presentation,
            nodeSizeLookup: nodeSizeLookup,
            gap: layoutParameters(for: presentation).nodeGap,
            maxIterations: overlapIterations
        )
        limitSpreadIfNeeded(graph: graph, presentation: presentation, nodeSizeLookup: nodeSizeLookup)
        resolveRemainingOverlaps(
            graph: graph,
            presentation: presentation,
            nodeSizeLookup: nodeSizeLookup,
            gap: layoutParameters(for: presentation).nodeGap * 0.72,
            maxIterations: overlapIterations
        )
        isAnimating = false
        velocities = Dictionary(uniqueKeysWithValues: velocities.keys.map { ($0, .zero) })
        hasSettledLayout = true
    }

    private func generateInitialPositions(
        for graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?
    ) {
        positions.removeAll(keepingCapacity: true)
        velocities.removeAll(keepingCapacity: true)
        pinnedPositions.removeAll(keepingCapacity: true)
        settledSteps = 0
        tickCount = 0
        hasRestoredSnapshot = false
        hasSettledLayout = false

        // Build clusters based on shared connections
        let clusters = buildClusters(for: graph)
        
        // Calculate node importance (degree + column count)
        let nodeWeights = Dictionary(uniqueKeysWithValues: graph.nodes.map { node in
            let weight = (descriptorLookup?(node.id)?.columns.count ?? 0) + graph.neighbors(of: node.id).count
            return (node.id, weight)
        })
        
        let rankedNodes = graph.nodes.sorted { lhs, rhs in
            let lhsWeight = nodeWeights[lhs.id] ?? 0
            let rhsWeight = nodeWeights[rhs.id] ?? 0
            if lhsWeight == rhsWeight {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhsWeight > rhsWeight
        }

        if presentation == .compact, graph.nodes.count > Self.largeGraphOverviewThreshold {
            generateLargeCompactOverviewPositions(for: rankedNodes, clusters: clusters, weights: nodeWeights)
            isAnimating = !graph.nodes.isEmpty
            StudioLog.graph.info("Reset large graph layout for \(graph.nodes.count, privacy: .public) nodes using bounded overview placement")
            return
        }

        // Use hierarchical layout within each cluster
        let clusterNodes = Dictionary(grouping: rankedNodes) { clusters[$0.id] ?? -1 }
        let clusterCount = max((clusters.values.max() ?? 0) + 1, 1)

        let smallAllCards = presentation == .allCards && graph.nodes.count < Self.crowdedNodeThreshold
        let baseRadius: Double = smallAllCards ? 94 : (presentation == .allCards ? 130 : 45)
        let baseClusterSpacing: Double = smallAllCards ? 0 : (presentation == .allCards ? 60 : 0)
        let layerSpacing: Double = smallAllCards ? 92 : (presentation == .allCards ? 75 : 35)
        let minNodeSpacing: Double = smallAllCards ? 104 : (presentation == .allCards ? 82 : 40)

        // Real card footprint (approximate). The physics step uses precise sizes when a
        // lookup is provided, but the *initial placement* needs realistic numbers too —
        // otherwise a 14-spoke ring at radius=80 places nodes 35px apart while cards are
        // ~150px wide, and overlap-correction never fully recovers.
        let approxCardWidth: Double = presentation == .allCards ? 280 : 160

        // Radius needed so that N nodes of width W don't visually touch on a single ring:
        // 2π·R ≈ N·W. Pad ×1.05 so cards don't kiss.
        func ringRadiusForCount(_ count: Int) -> Double {
            (Double(max(count, 1)) * approxCardWidth) / (2 * .pi) * 1.05
        }

        // For crowded graphs with multiple clusters, place cluster centers far enough apart
        // that their bounding circles don't collapse onto each other. With baseClusterSpacing=0
        // (the compact-mode default), every cluster center otherwise spawns at the origin
        // and the physics engine can't pry them apart — nodes pile up.
        let perClusterMinLayerStep = max(layerSpacing, approxCardWidth * 0.85)
        let clusterSpacing: Double = {
            guard clusterCount > 1, graph.nodes.count > Self.crowdedNodeThreshold else {
                return baseClusterSpacing
            }
            // Each cluster's worst-case reach is layer 1: either the width-based ring or the
            // minimum hub-to-spoke step, whichever is greater. Must mirror the layerRadius
            // formula below; otherwise small clusters underestimate and end up overlapping.
            var maxClusterRadius = baseRadius
            for nodes in clusterNodes.values {
                let spokeCount = max(nodes.count - 1, 1)
                let widthBased = ringRadiusForCount(spokeCount)
                let outerRadius = max(baseRadius, perClusterMinLayerStep, widthBased)
                maxClusterRadius = max(maxClusterRadius, outerRadius)
            }
            let safeSin = max(sin(.pi / Double(clusterCount)), 0.18)
            return max(baseClusterSpacing, maxClusterRadius * 1.8 / safeSin)
        }()

        for clusterID in clusterNodes.keys.sorted() {
            let nodesInCluster = clusterNodes[clusterID] ?? []
            let clusterAngle = Double(clusterID) * (2.0 * .pi / Double(clusterCount))
            let clusterCenter = CGPoint(
                x: cos(clusterAngle) * clusterSpacing,
                y: sin(clusterAngle) * clusterSpacing
            )
            
            // Check if this is an isolated nodes cluster (all nodes have no connections)
            let isIsolatedCluster = nodesInCluster.allSatisfy { node in
                graph.neighbors(of: node.id).isEmpty
            }
            
            if isIsolatedCluster {
                // Use a compact grid layout for isolated nodes
                let gridSpacing: Double = smallAllCards ? 132 : (presentation == .allCards ? 85 : 48)
                let nodesPerRow = max(Int(sqrt(Double(nodesInCluster.count))), 1)
                
                for (index, node) in nodesInCluster.enumerated() {
                    let row = index / nodesPerRow
                    let col = index % nodesPerRow
                    let offsetX = (Double(col) - Double(nodesPerRow - 1) * 0.5) * gridSpacing
                    let offsetY = (Double(row) - Double((nodesInCluster.count - 1) / nodesPerRow) * 0.5) * gridSpacing
                    
                    var point = CGPoint(
                        x: clusterCenter.x + offsetX,
                        y: clusterCenter.y + offsetY
                    )
                    
                    // Check for collisions with already placed nodes
                    var attempts = 0
                    while attempts < 10 {
                        var hasCollision = false
                        for (_, placedPos) in positions {
                            let distance = hypot(point.x - placedPos.x, point.y - placedPos.y)
                            if distance < minNodeSpacing {
                                hasCollision = true
                                let pushAngle = atan2(point.y - placedPos.y, point.x - placedPos.x)
                                point.x += cos(pushAngle) * (minNodeSpacing - distance)
                                point.y += sin(pushAngle) * (minNodeSpacing - distance)
                                break
                            }
                        }
                        if !hasCollision {
                            break
                        }
                        attempts += 1
                    }
                    
                    positions[node.id] = point
                    velocities[node.id] = .zero
                }
            } else {
                // Build a hierarchical layout for connected clusters
                let hierarchy = buildHierarchy(for: nodesInCluster, in: graph, weights: nodeWeights)
                // Spokes radiate in all directions — a layer placed at the cardHeight distance
                // overlaps the hub horizontally. The minimum step is the card *width* with
                // a small gap, so even a single-spoke cluster clears the hub card.
                let minLayerStep = perClusterMinLayerStep

                // Position nodes in layers radiating from cluster center
                var previousLayerRadius: Double = 0
                for (layerIndex, layer) in hierarchy.enumerated() {
                    let layerRadius: Double
                    if layerIndex == 0 {
                        // True hub: single node sits at the cluster center, not on a tiny ring.
                        layerRadius = 0
                    } else {
                        let widthBased = ringRadiusForCount(layer.count)
                        let stepFromPrevious = previousLayerRadius + minLayerStep
                        layerRadius = max(baseRadius, stepFromPrevious, widthBased)
                    }
                    previousLayerRadius = layerRadius

                    let angleStep = layer.count > 0 ? (2.0 * .pi) / Double(layer.count) : 0
                    for (indexInLayer, nodeID) in layer.enumerated() {
                        let seed = stableSeed(for: nodeID)
                        let jitter = Double(seed % 40) - 20.0
                        let angle = Double(indexInLayer) * angleStep + clusterAngle + (jitter * 0.01)

                        var point = CGPoint(
                            x: clusterCenter.x + cos(angle) * layerRadius,
                            y: clusterCenter.y + sin(angle) * layerRadius
                        )
                        
                        // Check for collisions with already placed nodes and adjust if needed
                        var attempts = 0
                        while attempts < 10 {
                            var hasCollision = false
                            for (_, placedPos) in positions {
                                let distance = hypot(point.x - placedPos.x, point.y - placedPos.y)
                                if distance < minNodeSpacing {
                                    hasCollision = true
                                    // Push away from collision
                                    let pushAngle = atan2(point.y - placedPos.y, point.x - placedPos.x)
                                    point.x += cos(pushAngle) * (minNodeSpacing - distance)
                                    point.y += sin(pushAngle) * (minNodeSpacing - distance)
                                    break
                                }
                            }
                            if !hasCollision {
                                break
                            }
                            attempts += 1
                        }
                        
                        positions[nodeID] = point
                        velocities[nodeID] = .zero
                    }
                }
            }
        }

        isAnimating = !graph.nodes.isEmpty
        StudioLog.graph.info("Reset graph layout for \(graph.nodes.count, privacy: .public) nodes with \(clusterCount, privacy: .public) clusters")
    }

    private func generateLargeCompactOverviewPositions(
        for rankedNodes: [GraphNode],
        clusters: [String: Int],
        weights: [String: Int]
    ) {
        let overviewNodes = rankedNodes.sorted { lhs, rhs in
            let lhsCluster = clusters[lhs.id] ?? Int.max
            let rhsCluster = clusters[rhs.id] ?? Int.max
            if lhsCluster != rhsCluster {
                return lhsCluster < rhsCluster
            }

            let lhsWeight = weights[lhs.id] ?? 0
            let rhsWeight = weights[rhs.id] ?? 0
            if lhsWeight == rhsWeight {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhsWeight > rhsWeight
        }

        // Keep the overview close to the viewport's aspect ratio while leaving enough
        // room for the widest collapsed card. Cards are rendered at the fitted zoom, so
        // this grid remains legible and clickable without the radial layout's enormous
        // outer rings.
        let columns = max(1, Int(ceil(sqrt(Double(overviewNodes.count) * 0.45))))
        let rows = max(1, Int(ceil(Double(overviewNodes.count) / Double(columns))))
        let columnSpacing: CGFloat = 410
        let rowSpacing: CGFloat = 74

        for (index, node) in overviewNodes.enumerated() {
            let row = index / columns
            let column = index % columns
            positions[node.id] = CGPoint(
                x: (CGFloat(column) - CGFloat(columns - 1) * 0.5) * columnSpacing,
                y: (CGFloat(row) - CGFloat(rows - 1) * 0.5) * rowSpacing
            )
            velocities[node.id] = .zero
        }
    }
    
    private func buildHierarchy(for nodes: [GraphNode], in graph: SchemaGraph, weights: [String: Int]) -> [[String]] {
        guard !nodes.isEmpty else { return [] }
        
        var layers: [[String]] = []
        var placed: Set<String> = []
        var remaining = Set(nodes.map(\.id))
        
        // Start with the most connected node
        if let rootNode = nodes.max(by: { (weights[$0.id] ?? 0) < (weights[$1.id] ?? 0) }) {
            layers.append([rootNode.id])
            placed.insert(rootNode.id)
            remaining.remove(rootNode.id)
        }
        
        // Build layers by expanding from placed nodes
        while !remaining.isEmpty {
            var nextLayer: [String] = []
            
            // Find nodes connected to the current layer
            for nodeID in remaining.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let neighbors = graph.neighbors(of: nodeID)
                if neighbors.intersection(placed).isEmpty {
                    continue
                }
                nextLayer.append(nodeID)
            }
            
            // If no connected nodes found, add the most connected remaining node
            if nextLayer.isEmpty, let nextNode = remaining.sorted(by: { lhs, rhs in
                let lhsWeight = weights[lhs] ?? 0
                let rhsWeight = weights[rhs] ?? 0
                if lhsWeight == rhsWeight {
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                return lhsWeight > rhsWeight
            }).first {
                nextLayer.append(nextNode)
            }
            
            // Sort layer by connection count for better visual balance
            nextLayer.sort { (weights[$0] ?? 0) > (weights[$1] ?? 0) }
            
            layers.append(nextLayer)
            for nodeID in nextLayer {
                placed.insert(nodeID)
                remaining.remove(nodeID)
            }
        }
        
        return layers
    }
    
    private func buildClusters(for graph: SchemaGraph) -> [String: Int] {
        var clusters: [String: Int] = [:]
        var nextClusterID = 0
        var visited: Set<String> = []

        // Step 1 — Apply AI-authored cluster hints first. Hinted tables ignore FK topology
        // so the user's grouping (e.g. "Auth", "Billing") wins over connected-components.
        if !clusterHintByNode.isEmpty {
            let validNodeIDs = Set(graph.nodes.map(\.id))
            var groupToID: [String: Int] = [:]
            for node in graph.nodes {
                guard let group = clusterHintByNode[node.id], validNodeIDs.contains(node.id) else { continue }
                if let id = groupToID[group] {
                    clusters[node.id] = id
                } else {
                    groupToID[group] = nextClusterID
                    clusters[node.id] = nextClusterID
                    nextClusterID += 1
                }
                visited.insert(node.id)
            }
        }

        // Build adjacency map for quick lookup
        var adjacency: [String: Set<String>] = [:]
        for edge in graph.edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }

        // Step 2 — Identify isolated unhinted nodes.
        var isolatedNodes: [String] = []
        for node in graph.nodes where !visited.contains(node.id) {
            if adjacency[node.id]?.isEmpty ?? true {
                isolatedNodes.append(node.id)
                visited.insert(node.id)
            }
        }

        // Step 3 — Find connected components among the remaining unhinted nodes.
        for node in graph.nodes {
            guard !visited.contains(node.id) else { continue }

            var queue = [node.id]
            var queueIndex = 0
            visited.insert(node.id)
            clusters[node.id] = nextClusterID

            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1

                for neighbor in adjacency[current, default: []].sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    guard !visited.contains(neighbor) else { continue }
                    visited.insert(neighbor)
                    clusters[neighbor] = nextClusterID
                    queue.append(neighbor)
                }
            }

            nextClusterID += 1
        }

        // Step 4 — All remaining isolated nodes share an orphan bucket.
        if !isolatedNodes.isEmpty {
            let orphanClusterID = nextClusterID
            for nodeID in isolatedNodes {
                clusters[nodeID] = orphanClusterID
            }
        }

        return clusters
    }

    public func position(for nodeID: String) -> CGPoint {
        positions[nodeID] ?? .zero
    }

    public func pin(nodeID: String, at position: CGPoint, shouldAnimate: Bool = false) {
        positions[nodeID] = position
        pinnedPositions[nodeID] = position
        velocities[nodeID] = .zero
        isAnimating = shouldAnimate
    }

    public func step(graph: SchemaGraph) {
        step(graph: graph, presentation: .compact, descriptorLookup: nil, nodeSizeLookup: nil)
    }

    func step(
        graph: SchemaGraph,
        presentation: GraphPresentationMode,
        descriptorLookup: ((String) -> EditableTableDescriptor?)?,
        nodeSizeLookup: ((String) -> CGSize)?
    ) {
        guard isAnimating, !graph.nodes.isEmpty else { return }
        reset(for: graph, presentation: presentation, descriptorLookup: descriptorLookup)
        tickCount += 1

        let parameters = layoutParameters(for: presentation)
        let clusters = buildClusters(for: graph)

        // When AI cluster hints are active, suppress forces that collapse clusters:
        // cross-cluster FK springs pull groups together, compaction/centering squashes them
        // toward the global centroid. Use per-cluster cohesion instead of global gravity.
        let hasClusterHints = !clusterHintByNode.isEmpty
        let smallAllCards = presentation == .allCards && graph.nodes.count < Self.crowdedNodeThreshold
        let effectiveClusterAttraction = hasClusterHints
            ? (smallAllCards ? 0.012 : 0.022)
            : parameters.clusterAttractionStrength
        let effectiveCenterStrength = hasClusterHints
            ? (smallAllCards ? 0.006 : 0.001)
            : parameters.centerStrength
        let effectiveCompaction = hasClusterHints
            ? (smallAllCards ? 0.014 : 0.0)
            : parameters.compactionStrength

        var forces: [String: CGVector] = [:]
        for node in graph.nodes {
            forces[node.id] = .zero
        }

        let nodes = graph.nodes
        let defaultNodeSize = CGSize(
            width: parameters.baseCollisionRadius * 2,
            height: parameters.baseCollisionRadius * 2
        )
        let nodeSizes = Dictionary(uniqueKeysWithValues: nodes.map { node in
            (node.id,
             effectiveLayoutSize(nodeSizeLookup?(node.id) ?? defaultNodeSize,
                                 presentation: presentation,
                                 nodeCount: nodes.count))
        })
        let shouldRepelNodesFromEdgePaths = presentation != .allCards || nodes.count <= 24
        let centroid = positionsCentroid(for: nodes)

        for leftIndex in 0..<nodes.count {
            let leftID = nodes[leftIndex].id
            let leftPosition = positions[leftID] ?? .zero
            let leftSize = nodeSizes[leftID] ?? defaultNodeSize
            let leftHalfWidth = Double(leftSize.width * 0.5)
            let leftHalfHeight = Double(leftSize.height * 0.5)

            for rightIndex in (leftIndex + 1)..<nodes.count {
                let rightID = nodes[rightIndex].id
                let rightPosition = positions[rightID] ?? .zero
                let rightSize = nodeSizes[rightID] ?? defaultNodeSize
                let rightHalfWidth = Double(rightSize.width * 0.5)
                let rightHalfHeight = Double(rightSize.height * 0.5)
                var delta = CGVector(dx: rightPosition.x - leftPosition.x, dy: rightPosition.y - leftPosition.y)
                let distanceSquared = max(delta.dx * delta.dx + delta.dy * delta.dy, 0.01)
                let distance = sqrt(distanceSquared)
                delta.dx /= distance
                delta.dy /= distance

                let repel = parameters.repelStrength / distanceSquared
                forces[leftID, default: .zero].dx -= delta.dx * repel
                forces[leftID, default: .zero].dy -= delta.dy * repel
                forces[rightID, default: .zero].dx += delta.dx * repel
                forces[rightID, default: .zero].dy += delta.dy * repel

                // Add clustering force: nodes in the same cluster attract each other
                if clusters[leftID] == clusters[rightID], let clusterID = clusters[leftID], clusterID >= 0 {
                    let clusterAttraction = effectiveClusterAttraction * distance
                    forces[leftID, default: .zero].dx += delta.dx * clusterAttraction
                    forces[leftID, default: .zero].dy += delta.dy * clusterAttraction
                    forces[rightID, default: .zero].dx -= delta.dx * clusterAttraction
                    forces[rightID, default: .zero].dy -= delta.dy * clusterAttraction
                }

                let overlapX = leftHalfWidth + rightHalfWidth + parameters.nodeGap - abs(rightPosition.x - leftPosition.x)
                let overlapY = leftHalfHeight + rightHalfHeight + parameters.nodeGap - abs(rightPosition.y - leftPosition.y)
                if overlapX > 0, overlapY > 0 {
                    // Strong separation force to prevent overlap
                    let overlapMagnitude = sqrt(overlapX * overlapX + overlapY * overlapY)
                    let separationStrength = overlapMagnitude * parameters.overlapCorrectionStrength
                    
                    // Prefer horizontal separation to avoid vertical stacking bias.
                    // When overlaps are nearly equal (within 4 pt), always separate on X.
                    if overlapX <= overlapY + 4.0 {
                        let sign = rightPosition.x >= leftPosition.x ? 1.0 : -1.0
                        forces[leftID, default: .zero].dx -= sign * separationStrength
                        forces[rightID, default: .zero].dx += sign * separationStrength
                    } else {
                        let sign = rightPosition.y >= leftPosition.y ? 1.0 : -1.0
                        forces[leftID, default: .zero].dy -= sign * separationStrength
                        forces[rightID, default: .zero].dy += sign * separationStrength
                    }
                }
            }
        }

        for edge in graph.edges {
            let source = positions[edge.sourceID] ?? .zero
            let target = positions[edge.targetID] ?? .zero
            let sourceSize = nodeSizes[edge.sourceID] ?? defaultNodeSize
            let targetSize = nodeSizes[edge.targetID] ?? defaultNodeSize
            var delta = CGVector(dx: target.x - source.x, dy: target.y - source.y)
            let distance = max(sqrt(delta.dx * delta.dx + delta.dy * delta.dy), 0.01)
            delta.dx /= distance
            delta.dy /= distance

            let desiredLinkDistance = parameters.linkDistance
                + max(
                    Double(sourceSize.width + targetSize.width) * 0.5,
                    Double(sourceSize.height + targetSize.height) * 0.5
                ) * parameters.linkRadiusFactor
            // Keep larger explicit cluster islands distinct, but let small graphs and
            // unhinted nodes use FK springs so they stay close to the rest of the graph.
            let sourceHasExplicitCluster = clusterHintByNode[edge.sourceID] != nil
            let targetHasExplicitCluster = clusterHintByNode[edge.targetID] != nil
            let shouldKeepExplicitClustersDistinct = !smallAllCards && sourceHasExplicitCluster && targetHasExplicitCluster
            let isCrossCluster = hasClusterHints
                && shouldKeepExplicitClustersDistinct
                && clusters[edge.sourceID] != clusters[edge.targetID]
            if !isCrossCluster {
                let pull = (distance - desiredLinkDistance) * parameters.springStrength
                forces[edge.sourceID, default: .zero].dx += delta.dx * pull
                forces[edge.sourceID, default: .zero].dy += delta.dy * pull
                forces[edge.targetID, default: .zero].dx -= delta.dx * pull
                forces[edge.targetID, default: .zero].dy -= delta.dy * pull
            }

            if shouldRepelNodesFromEdgePaths {
                // Push unrelated nodes away from edge paths. This is expensive on dense
                // all-card graphs, where card overlap correction gives a better payoff.
                for node in nodes where node.id != edge.sourceID && node.id != edge.targetID {
                    let nodePos = positions[node.id] ?? .zero
                    let nodeSize = nodeSizes[node.id] ?? defaultNodeSize
                    
                    // Calculate closest point on edge line segment
                    let edgeVec = CGVector(dx: target.x - source.x, dy: target.y - source.y)
                    let nodeVec = CGVector(dx: nodePos.x - source.x, dy: nodePos.y - source.y)
                    let edgeLengthSquared = max(edgeVec.dx * edgeVec.dx + edgeVec.dy * edgeVec.dy, 0.01)
                    let t = max(0, min(1, (nodeVec.dx * edgeVec.dx + nodeVec.dy * edgeVec.dy) / edgeLengthSquared))
                    
                    let closestPoint = CGPoint(
                        x: source.x + t * edgeVec.dx,
                        y: source.y + t * edgeVec.dy
                    )
                    
                    let distToEdge = hypot(nodePos.x - closestPoint.x, nodePos.y - closestPoint.y)
                    let clearanceNeeded = max(nodeSize.width, nodeSize.height) * 0.5 + parameters.edgeClearance
                    
                    if distToEdge < clearanceNeeded {
                        let pushStrength = (clearanceNeeded - distToEdge) * parameters.edgeRepelStrength
                        let pushDir = CGVector(
                            dx: (nodePos.x - closestPoint.x) / max(distToEdge, 0.01),
                            dy: (nodePos.y - closestPoint.y) / max(distToEdge, 0.01)
                        )
                        forces[node.id, default: .zero].dx += pushDir.dx * pushStrength
                        forces[node.id, default: .zero].dy += pushDir.dy * pushStrength
                    }
                }
            }

            guard presentation == .allCards,
                  let descriptorLookup,
                  let sourceDescriptor = descriptorLookup(edge.sourceID),
                  let targetDescriptor = descriptorLookup(edge.targetID),
                  let sourceIndex = sourceDescriptor.columns.firstIndex(where: { $0.name == edge.sourceColumn }),
                  let targetIndex = targetDescriptor.columns.firstIndex(where: { $0.name == edge.targetColumn })
            else {
                continue
            }

            let desiredDeltaY = Double(targetIndex - sourceIndex) * Double(GraphCardLayout.expandedRowHeight)
            let currentDeltaY = target.y - source.y
            let correction = (currentDeltaY - desiredDeltaY) * parameters.columnAlignmentStrength
            forces[edge.sourceID, default: .zero].dy += correction
            forces[edge.targetID, default: .zero].dy -= correction
        }

        var totalVelocity = 0.0
        for node in nodes {
            let current = positions[node.id] ?? .zero
            let centered = CGVector(dx: -current.x * effectiveCenterStrength, dy: -current.y * effectiveCenterStrength)
            let compacted = CGVector(
                dx: (centroid.x - current.x) * effectiveCompaction,
                dy: (centroid.y - current.y) * effectiveCompaction
            )
            let applied = CGVector(
                dx: forces[node.id, default: .zero].dx + centered.dx + compacted.dx,
                dy: forces[node.id, default: .zero].dy + centered.dy + compacted.dy
            )

            if let pinned = pinnedPositions[node.id] {
                positions[node.id] = pinned
                velocities[node.id] = .zero
                continue
            }

            var velocity = velocities[node.id] ?? .zero
            velocity.dx = (velocity.dx + applied.dx) * parameters.damping
            velocity.dy = (velocity.dy + applied.dy) * parameters.damping
            positions[node.id] = CGPoint(x: current.x + velocity.dx, y: current.y + velocity.dy)
            velocities[node.id] = velocity
            totalVelocity += abs(velocity.dx) + abs(velocity.dy)
        }

        if totalVelocity < 0.24 {
            settledSteps += 1
        } else {
            settledSteps = 0
        }

        if settledSteps > 24 {
            isAnimating = false
            StudioLog.graph.info("Graph layout settled after \(self.tickCount, privacy: .public) ticks")
        } else if tickCount.isMultiple(of: 60) {
            StudioLog.graph.debug("Graph layout tick \(self.tickCount, privacy: .public)")
        }
    }

    public func nearestNode(to point: CGPoint, in graph: SchemaGraph, radius: CGFloat = 28) -> String? {
        var best: (id: String, distance: CGFloat)?
        for node in graph.nodes {
            let position = positions[node.id] ?? .zero
            let distance = hypot(position.x - point.x, position.y - point.y)
            guard distance <= radius else { continue }
            if let best, best.distance <= distance {
                continue
            }
            best = (node.id, distance)
        }
        return best?.id
    }

    private func stableSeed(for input: String) -> UInt64 {
        input.utf8.reduce(14_695_981_039_346_656_037) { partial, byte in
            ((partial ^ UInt64(byte)) &* 1_099_511_628_211) ^ layoutSeedOffset
        }
    }

    private func layoutParameters(for presentation: GraphPresentationMode) -> LayoutParameters {
        switch presentation {
        case .compact:
            return LayoutParameters(
                linkDistance: 50,
                repelStrength: 2_200,
                springStrength: 0.035,
                centerStrength: 0.018,
                baseCollisionRadius: 30,
                nodeGap: 30,
                linkRadiusFactor: 0.22,
                damping: 0.86,
                columnAlignmentStrength: 0,
                clusterAttractionStrength: 0.010,
                compactionStrength: 0.008,
                edgeClearance: 58,
                edgeRepelStrength: 0.25,
                overlapCorrectionStrength: 2.6
            )
        case .allCards:
            if positions.count > 0 && positions.count < Self.crowdedNodeThreshold {
                return LayoutParameters(
                    linkDistance: 160,
                    repelStrength: 9_200,
                    springStrength: 0.036,
                    centerStrength: 0.030,
                    baseCollisionRadius: 78,
                    nodeGap: 48,
                    linkRadiusFactor: 0.42,
                    damping: 0.86,
                    columnAlignmentStrength: 0.010,
                    clusterAttractionStrength: 0.008,
                    compactionStrength: 0.022,
                    edgeClearance: 52,
                    edgeRepelStrength: 0.25,
                    overlapCorrectionStrength: 2.6
                )
            }
            return LayoutParameters(
                linkDistance: 180,
                repelStrength: 16_000,
                springStrength: 0.026,
                centerStrength: 0.012,
                baseCollisionRadius: 120,
                nodeGap: 68,
                linkRadiusFactor: 0.42,
                damping: 0.84,
                columnAlignmentStrength: 0.014,
                clusterAttractionStrength: 0.010,
                compactionStrength: 0.004,
                edgeClearance: 58,
                edgeRepelStrength: 0.28,
                overlapCorrectionStrength: 2.2
            )
        }
    }

    private func resolveRemainingOverlaps(
        graph: SchemaGraph,
        presentation: GraphPresentationMode,
        nodeSizeLookup: ((String) -> CGSize)?,
        gap: Double,
        maxIterations: Int = 80
    ) {
        let orderedNodes = graph.nodes.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        guard orderedNodes.count > 1 else { return }

        for _ in 0..<maxIterations {
            var moved = false

            for leftIndex in 0..<orderedNodes.count {
                let leftID = orderedNodes[leftIndex].id
                let leftPosition = positions[leftID] ?? .zero
                let leftSize = effectiveLayoutSize(
                    nodeSizeLookup?(leftID) ?? CGSize(width: 120, height: 80),
                    presentation: presentation,
                    nodeCount: orderedNodes.count
                )

                for rightIndex in (leftIndex + 1)..<orderedNodes.count {
                    let rightID = orderedNodes[rightIndex].id
                    let rightPosition = positions[rightID] ?? .zero
                    let rightSize = effectiveLayoutSize(
                        nodeSizeLookup?(rightID) ?? CGSize(width: 120, height: 80),
                        presentation: presentation,
                        nodeCount: orderedNodes.count
                    )

                    let overlapX = Double(leftSize.width + rightSize.width) * 0.5 + gap - abs(rightPosition.x - leftPosition.x)
                    let overlapY = Double(leftSize.height + rightSize.height) * 0.5 + gap - abs(rightPosition.y - leftPosition.y)
                    guard overlapX > 0, overlapY > 0 else { continue }

                    let leftPinned = pinnedPositions[leftID] != nil
                    let rightPinned = pinnedPositions[rightID] != nil
                    guard !(leftPinned && rightPinned) else { continue }

                    // Prefer horizontal separation to avoid vertical stacking bias.
                    // When overlaps are nearly equal (within 4 pt), always separate on X.
                    let separateOnX = overlapX <= overlapY + 4.0
                    let sign = separateOnX
                        ? (rightPosition.x >= leftPosition.x ? 1.0 : -1.0)
                        : (rightPosition.y >= leftPosition.y ? 1.0 : -1.0)
                    let distance = (separateOnX ? overlapX : overlapY) * 0.5 + 1

                    if leftPinned || rightPinned {
                        let movableID = leftPinned ? rightID : leftID
                        let direction = leftPinned ? sign : -sign
                        var movablePosition = positions[movableID] ?? .zero
                        if separateOnX {
                            movablePosition.x += direction * distance * 2
                        } else {
                            movablePosition.y += direction * distance * 2
                        }
                        positions[movableID] = movablePosition
                    } else {
                        var nextLeft = leftPosition
                        var nextRight = rightPosition
                        if separateOnX {
                            nextLeft.x -= sign * distance
                            nextRight.x += sign * distance
                        } else {
                            nextLeft.y -= sign * distance
                            nextRight.y += sign * distance
                        }
                        positions[leftID] = nextLeft
                        positions[rightID] = nextRight
                    }

                    moved = true
                }
            }

            if !moved {
                break
            }
        }
    }

    private func limitSpreadIfNeeded(
        graph: SchemaGraph,
        presentation: GraphPresentationMode,
        nodeSizeLookup: ((String) -> CGSize)?
    ) {
        // Crowded graphs are left at their natural spread — squeezing many nodes back
        // into an aspect-ratio-bounded box is what makes them visually overlap. The user
        // pans/zooms manually past this threshold.
        guard pinnedPositions.isEmpty,
              graph.nodes.count > 2,
              graph.nodes.count <= Self.crowdedNodeThreshold
        else { return }

        let frames = graph.nodes.map { node -> CGRect in
            let position = positions[node.id] ?? .zero
            let size = effectiveLayoutSize(
                nodeSizeLookup?(node.id) ?? CGSize(width: 160, height: 80),
                presentation: presentation,
                nodeCount: graph.nodes.count
            )
            return CGRect(
                x: position.x - size.width / 2,
                y: position.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        let bounds = frames.reduce(into: CGRect.null) { partial, frame in
            partial = partial.union(frame)
        }
        guard !bounds.isNull, !bounds.isEmpty else { return }

        let nodeFactor = sqrt(Double(graph.nodes.count))
        let smallAllCards = presentation == .allCards && graph.nodes.count < 14
        let maxWidth = smallAllCards ? max(720, nodeFactor * 205)
            : (presentation == .allCards ? max(1_400, nodeFactor * 390) : max(820, nodeFactor * 130))
        let maxHeight = smallAllCards ? max(600, nodeFactor * 190)
            : (presentation == .allCards ? max(1_100, nodeFactor * 360) : max(620, nodeFactor * 115))
        let maxAspectRatio = presentation == .allCards ? 1.55 : 1.36

        var targetWidth = min(Double(bounds.width), maxWidth)
        var targetHeight = min(Double(bounds.height), maxHeight)

        if bounds.width > bounds.height * maxAspectRatio {
            targetWidth = min(targetWidth, Double(bounds.height) * maxAspectRatio)
        }
        if bounds.height > bounds.width * maxAspectRatio {
            targetHeight = min(targetHeight, Double(bounds.width) * maxAspectRatio)
        }

        let minimumScale = smallAllCards ? 0.58 : (presentation == .allCards ? 0.72 : 0.50)
        let scaleX = min(1, max(minimumScale, targetWidth / max(Double(bounds.width), 1)))
        let scaleY = min(1, max(minimumScale, targetHeight / max(Double(bounds.height), 1)))
        guard scaleX < 0.995 || scaleY < 0.995 else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for node in graph.nodes {
            let position = positions[node.id] ?? .zero
            positions[node.id] = CGPoint(
                x: center.x + (position.x - center.x) * scaleX,
                y: center.y + (position.y - center.y) * scaleY
            )
        }
    }

    private func effectiveLayoutSize(
        _ size: CGSize,
        presentation: GraphPresentationMode,
        nodeCount: Int
    ) -> CGSize {
        guard presentation == .compact else { return size }
        if nodeCount > 80 {
            return CGSize(width: min(size.width, 96), height: min(size.height, 38))
        }
        if nodeCount > 24 {
            return CGSize(width: min(size.width, 132), height: min(size.height, 42))
        }
        return size
    }

    private func positionsCentroid(for nodes: [GraphNode]) -> CGPoint {
        guard !nodes.isEmpty else { return .zero }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for node in nodes {
            let position = positions[node.id] ?? .zero
            sumX += position.x
            sumY += position.y
        }
        return CGPoint(
            x: sumX / CGFloat(nodes.count),
            y: sumY / CGFloat(nodes.count)
        )
    }
}

private struct LayoutParameters {
    let linkDistance: Double
    let repelStrength: Double
    let springStrength: Double
    let centerStrength: Double
    let baseCollisionRadius: Double
    let nodeGap: Double
    let linkRadiusFactor: Double
    let damping: Double
    let columnAlignmentStrength: Double
    let clusterAttractionStrength: Double
    let compactionStrength: Double
    let edgeClearance: Double
    let edgeRepelStrength: Double
    let overlapCorrectionStrength: Double
}
