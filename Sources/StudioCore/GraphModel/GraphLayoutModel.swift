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

        let rankedNodes = graph.nodes.sorted { lhs, rhs in
            let lhsWeight = (descriptorLookup?(lhs.id)?.columns.count ?? 0) + graph.neighbors(of: lhs.id).count
            let rhsWeight = (descriptorLookup?(rhs.id)?.columns.count ?? 0) + graph.neighbors(of: rhs.id).count
            if lhsWeight == rhsWeight {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhsWeight > rhsWeight
        }

        let ringSpacing: Double = presentation == .allCards ? 34 : 18
        let baseRadius: Double = presentation == .allCards ? 180 : 140

        for (index, node) in rankedNodes.enumerated() {
            let seed = stableSeed(for: node.id)
            let angle = Double(seed % 360) * .pi / 180.0
            let radius = baseRadius + Double(index % 7) * ringSpacing + Double(seed % 23)
            let point = CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
            positions[node.id] = point
            velocities[node.id] = .zero
        }

        isAnimating = !graph.nodes.isEmpty
        StudioLog.graph.info("Reset graph layout for \(graph.nodes.count, privacy: .public) nodes")
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

                let overlapX = leftHalfWidth + rightHalfWidth + parameters.nodeGap - abs(rightPosition.x - leftPosition.x)
                let overlapY = leftHalfHeight + rightHalfHeight + parameters.nodeGap - abs(rightPosition.y - leftPosition.y)
                if overlapX > 0, overlapY > 0 {
                    if overlapX < overlapY {
                        let sign = rightPosition.x >= leftPosition.x ? 1.0 : -1.0
                        let correction = overlapX * 0.5
                        forces[leftID, default: .zero].dx -= sign * correction
                        forces[rightID, default: .zero].dx += sign * correction
                    } else {
                        let sign = rightPosition.y >= leftPosition.y ? 1.0 : -1.0
                        let correction = overlapY * 0.5
                        forces[leftID, default: .zero].dy -= sign * correction
                        forces[rightID, default: .zero].dy += sign * correction
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
                linkDistance: 156,
                repelStrength: 8_600,
                springStrength: 0.017,
                centerStrength: 0.01,
                baseCollisionRadius: 30,
                nodeGap: 28,
                linkRadiusFactor: 0.42,
                damping: 0.88,
                columnAlignmentStrength: 0
            )
        case .allCards:
            return LayoutParameters(
                linkDistance: 276,
                repelStrength: 22_000,
                springStrength: 0.021,
                centerStrength: 0.007,
                baseCollisionRadius: 120,
                nodeGap: 62,
                linkRadiusFactor: 0.56,
                damping: 0.84,
                columnAlignmentStrength: 0.014
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
}
