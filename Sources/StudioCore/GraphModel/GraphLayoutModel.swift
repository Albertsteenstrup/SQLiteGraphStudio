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
    private var positions: [String: CGPoint] = [:]
    private var velocities: [String: CGVector] = [:]
    private var pinnedPositions: [String: CGPoint] = [:]
    private var latestGraphSignature: Int = 0
    private var layoutSeedOffset: UInt64 = 0
    private var settledSteps = 0
    private var tickCount = 0
    private var latestPresentationMode: GraphPresentationMode = .compact

    public private(set) var isAnimating = false
    public private(set) var hasRestoredSnapshot = false

    public init() {}

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

        for _ in 0..<maxIterations where isAnimating {
            step(
                graph: graph,
                presentation: presentation,
                descriptorLookup: descriptorLookup,
                nodeSizeLookup: nodeSizeLookup
            )
        }

        isAnimating = false
        velocities = Dictionary(uniqueKeysWithValues: velocities.keys.map { ($0, .zero) })
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

        // Use hierarchical layout within each cluster
        let clusterNodes = Dictionary(grouping: rankedNodes) { clusters[$0.id] ?? -1 }
        let clusterCount = max((clusters.values.max() ?? 0) + 1, 1)
        
        // Very tight spacing - nodes should be close together
        let baseRadius: Double = presentation == .allCards ? 130 : 45
        let clusterSpacing: Double = presentation == .allCards ? 60 : 0  // Clusters right next to each other
        let layerSpacing: Double = presentation == .allCards ? 75 : 35
        let minNodeSpacing: Double = presentation == .allCards ? 82 : 40

        for (clusterID, nodesInCluster) in clusterNodes {
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
                let gridSpacing: Double = presentation == .allCards ? 85 : 48
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
                
                // Position nodes in layers radiating from cluster center
                for (layerIndex, layer) in hierarchy.enumerated() {
                    let layerRadius = baseRadius + Double(layerIndex) * layerSpacing
                    let angleStep = max((2.0 * .pi) / Double(layer.count), 0.3) // Ensure minimum angular spacing
                    
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
            for nodeID in remaining {
                let neighbors = graph.neighbors(of: nodeID)
                if neighbors.intersection(placed).isEmpty {
                    continue
                }
                nextLayer.append(nodeID)
            }
            
            // If no connected nodes found, add the most connected remaining node
            if nextLayer.isEmpty, let nextNode = remaining.max(by: { 
                (weights[$0] ?? 0) < (weights[$1] ?? 0)
            }) {
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
        var clusterID = 0
        var visited: Set<String> = []
        
        // Build adjacency map for quick lookup
        var adjacency: [String: Set<String>] = [:]
        for edge in graph.edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }
        
        // First, identify isolated nodes (no connections)
        var isolatedNodes: [String] = []
        for node in graph.nodes {
            if adjacency[node.id]?.isEmpty ?? true {
                isolatedNodes.append(node.id)
                visited.insert(node.id)
            }
        }
        
        // Find connected components and assign cluster IDs
        for node in graph.nodes {
            guard !visited.contains(node.id) else { continue }
            
            // BFS to find all nodes in this cluster
            var queue = [node.id]
            var queueIndex = 0
            visited.insert(node.id)
            clusters[node.id] = clusterID
            
            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1
                
                for neighbor in adjacency[current, default: []] {
                    guard !visited.contains(neighbor) else { continue }
                    visited.insert(neighbor)
                    clusters[neighbor] = clusterID
                    queue.append(neighbor)
                }
            }
            
            clusterID += 1
        }
        
        // Assign all isolated nodes to a single "orphan" cluster
        if !isolatedNodes.isEmpty {
            let orphanClusterID = clusterID
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

        var forces: [String: CGVector] = [:]
        for node in graph.nodes {
            forces[node.id] = .zero
        }

        let nodes = graph.nodes
        for leftIndex in 0..<nodes.count {
            let leftID = nodes[leftIndex].id
            let leftPosition = positions[leftID] ?? .zero
            let leftSize = nodeSizeLookup?(leftID) ?? CGSize(
                width: parameters.baseCollisionRadius * 2,
                height: parameters.baseCollisionRadius * 2
            )
            let leftHalfWidth = Double(leftSize.width * 0.5)
            let leftHalfHeight = Double(leftSize.height * 0.5)

            for rightIndex in (leftIndex + 1)..<nodes.count {
                let rightID = nodes[rightIndex].id
                let rightPosition = positions[rightID] ?? .zero
                let rightSize = nodeSizeLookup?(rightID) ?? CGSize(
                    width: parameters.baseCollisionRadius * 2,
                    height: parameters.baseCollisionRadius * 2
                )
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
                    let clusterAttraction = parameters.clusterAttractionStrength * distance
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
                    
                    if overlapX < overlapY {
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
            let sourceSize = nodeSizeLookup?(edge.sourceID) ?? CGSize(
                width: parameters.baseCollisionRadius * 2,
                height: parameters.baseCollisionRadius * 2
            )
            let targetSize = nodeSizeLookup?(edge.targetID) ?? CGSize(
                width: parameters.baseCollisionRadius * 2,
                height: parameters.baseCollisionRadius * 2
            )
            var delta = CGVector(dx: target.x - source.x, dy: target.y - source.y)
            let distance = max(sqrt(delta.dx * delta.dx + delta.dy * delta.dy), 0.01)
            delta.dx /= distance
            delta.dy /= distance

            let desiredLinkDistance = parameters.linkDistance
                + max(
                    Double(sourceSize.width + targetSize.width) * 0.5,
                    Double(sourceSize.height + targetSize.height) * 0.5
                ) * parameters.linkRadiusFactor
            let pull = (distance - desiredLinkDistance) * parameters.springStrength
            forces[edge.sourceID, default: .zero].dx += delta.dx * pull
            forces[edge.sourceID, default: .zero].dy += delta.dy * pull
            forces[edge.targetID, default: .zero].dx -= delta.dx * pull
            forces[edge.targetID, default: .zero].dy -= delta.dy * pull

            // Push unrelated nodes away from edge paths
            for node in nodes where node.id != edge.sourceID && node.id != edge.targetID {
                let nodePos = positions[node.id] ?? .zero
                let nodeSize = nodeSizeLookup?(node.id) ?? CGSize(
                    width: parameters.baseCollisionRadius * 2,
                    height: parameters.baseCollisionRadius * 2
                )
                
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
            let centered = CGVector(dx: -current.x * parameters.centerStrength, dy: -current.y * parameters.centerStrength)
            let applied = CGVector(
                dx: forces[node.id, default: .zero].dx + centered.dx,
                dy: forces[node.id, default: .zero].dy + centered.dy
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
                clusterAttractionStrength: 0.024,
                edgeClearance: 22,
                edgeRepelStrength: 0.25,
                overlapCorrectionStrength: 2.6
            )
        case .allCards:
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
                edgeClearance: 58,
                edgeRepelStrength: 0.28,
                overlapCorrectionStrength: 2.2
            )
        }
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
    let edgeClearance: Double
    let edgeRepelStrength: Double
    let overlapCorrectionStrength: Double
}
