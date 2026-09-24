import CoreGraphics
import Foundation

/// Work counters make the bounded solver budget observable without relying on a
/// machine-specific elapsed-time assertion.
struct LargeGraphLayoutMetrics {
    var partitionCount = 0
    var largestPartition = 0
    var physicsSteps = 0
    var pairEvaluations = 0
    var edgePathEvaluations = 0
    var obstacleChecks = 0
}

/// A hierarchy around the ordinary force solver. Small connected pieces keep
/// their hub-and-neighbour geometry, while card-aware placement gives every
/// table clearance. Weighted links place the resulting communities near one
/// another without collapsing the whole catalog into rows or a single ring.
/// Every node-pair operation is confined to a piece of at most 64 nodes.
@MainActor
enum LargeGraphLayout {
    nonisolated static let maximumLocalNodeCount = 64
    nonisolated static let maximumPhysicsIterations = 12

    struct LocalSolution {
        let positions: [String: CGPoint]
        let iterations: Int
        let repelsFromEdgePaths: Bool
    }

    struct Result {
        let positions: [String: CGPoint]
        let metrics: LargeGraphLayoutMetrics
    }

    private struct Piece {
        let group: String
        let nodeIDs: [String]
    }

    private struct Region {
        let positions: [String: CGPoint]
        let size: CGSize
    }

    private struct Item {
        let id: String
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    static func calculate(
        graph: SchemaGraph,
        hints: [String: String],
        presentation: GraphPresentationMode,
        sizes: [String: CGSize],
        previousPositions: [String: CGPoint]?,
        pins: [String: CGPoint],
        solve: (SchemaGraph, [String: CGPoint]?) -> LocalSolution
    ) -> Result {
        let nodes = graph.nodes.sorted { $0.id < $1.id }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let validIDs = Set(nodesByID.keys)
        var adjacencySets: [String: Set<String>] = [:]
        let validEdges = graph.edges.filter {
            validIDs.contains($0.sourceID) && validIDs.contains($0.targetID) && $0.sourceID != $0.targetID
        }
        for edge in validEdges {
            adjacencySets[edge.sourceID, default: []].insert(edge.targetID)
            adjacencySets[edge.targetID, default: []].insert(edge.sourceID)
        }
        let degree = adjacencySets.mapValues(\.count)
        func importanceOrder(_ lhs: String, _ rhs: String) -> Bool {
            let leftDegree = degree[lhs, default: 0]
            let rightDegree = degree[rhs, default: 0]
            return leftDegree == rightDegree ? lhs < rhs : leftDegree > rightDegree
        }
        let adjacency = adjacencySets.mapValues { $0.sorted(by: importanceOrder) }
        let groupByNode = groups(nodes: nodes, hints: hints, adjacency: adjacency)
        let membersByGroup = Dictionary(grouping: nodes.map(\.id)) { groupByNode[$0]! }
        var pieces: [Piece] = []
        var pieceByNode: [String: Int] = [:]

        for group in membersByGroup.keys.sorted() {
            let orderedIDs = membersByGroup[group]!.sorted(by: importanceOrder)
            var remaining = Set(orderedIDs)
            var rootIndex = 0
            while !remaining.isEmpty {
                while !remaining.contains(orderedIDs[rootIndex]) { rootIndex += 1 }
                var queue = [orderedIDs[rootIndex]]
                var queued = Set(queue)
                var queueIndex = 0
                var members: [String] = []
                while members.count < maximumLocalNodeCount {
                    if queueIndex == queue.count {
                        // Disconnected leftovers still share a bounded piece, rather
                        // than creating one solver and one region for every orphan.
                        while rootIndex < orderedIDs.count, !remaining.contains(orderedIDs[rootIndex]) { rootIndex += 1 }
                        guard rootIndex < orderedIDs.count else { break }
                        queue.append(orderedIDs[rootIndex])
                        queued.insert(orderedIDs[rootIndex])
                    }
                    let current = queue[queueIndex]
                    queueIndex += 1
                    guard remaining.remove(current) != nil else { continue }
                    members.append(current)
                    pieceByNode[current] = pieces.count
                    for neighbor in adjacency[current, default: []]
                    where groupByNode[neighbor] == group && remaining.contains(neighbor) {
                        if queued.insert(neighbor).inserted { queue.append(neighbor) }
                    }
                }
                pieces.append(Piece(group: group, nodeIDs: members))
            }
        }

        // Index edges once. Filtering the entire edge list for each local solver
        // would quietly reintroduce E * number-of-pieces work.
        var edgesByPiece: [Int: [GraphEdge]] = [:]
        var groupLinks: [String: [String: Int]] = [:]
        for edge in validEdges {
            if let piece = pieceByNode[edge.sourceID], piece == pieceByNode[edge.targetID] {
                edgesByPiece[piece, default: []].append(edge)
            }
            let sourceGroup = groupByNode[edge.sourceID]!
            let targetGroup = groupByNode[edge.targetID]!
            if sourceGroup != targetGroup {
                groupLinks[sourceGroup, default: [:]][targetGroup, default: 0] += 1
                groupLinks[targetGroup, default: [:]][sourceGroup, default: 0] += 1
            }
        }

        let nodeGap: CGFloat = presentation == .compact ? 24 : 36
        let pieceGap: CGFloat = presentation == .compact ? 48 : 72
        let groupGap: CGFloat = presentation == .compact ? 112 : 160
        var metrics = LargeGraphLayoutMetrics()
        var regionsByGroup: [String: [(id: String, region: Region)]] = [:]
        for (pieceIndex, piece) in pieces.enumerated() {
            let localNodes = piece.nodeIDs.sorted().compactMap { nodesByID[$0] }
            let localEdges = edgesByPiece[pieceIndex, default: []].sorted(by: edgeOrder)
            let localGraph = SchemaGraph(nodes: localNodes, edges: localEdges)
            let prior: [String: CGPoint]? = previousPositions.map { previous in
                Dictionary(uniqueKeysWithValues: piece.nodeIDs.compactMap { id -> (String, CGPoint)? in
                    guard let point = previous[id], isFinite(point) else { return nil }
                    return (id, point)
                })
            }
            let solution = solve(localGraph, prior)
            metrics.partitionCount += 1
            metrics.largestPartition = max(metrics.largestPartition, localNodes.count)
            metrics.physicsSteps += solution.iterations
            metrics.pairEvaluations += localNodes.count * max(localNodes.count - 1, 0) / 2 * solution.iterations
            if solution.repelsFromEdgePaths && (presentation == .compact || localNodes.count <= 24) {
                metrics.edgePathEvaluations += localEdges.count * max(localNodes.count - 2, 0) * solution.iterations
            }

            let orderedIDs = piece.nodeIDs.sorted { lhs, rhs in
                let left = finitePosition(solution.positions[lhs])
                let right = finitePosition(solution.positions[rhs])
                if left.y != right.y { return left.y < right.y }
                if left.x != right.x { return left.x < right.x }
                return lhs < rhs
            }
            let items = orderedIDs.map { Item(id: $0, size: sizes[$0]!) }
            // A normal domain group fits in one bounded piece. Keep its local
            // force solution so a connected hub actually has nearby spokes.
            // Very large pieces use the proven compact packer for predictable
            // work and clearance; their parent groups still use fabric placement.
            let region = items.count <= 48 && !localEdges.isEmpty
                ? fabric(items.sorted { importanceOrder($0.id, $1.id) },
                         preferred: solution.positions, gap: nodeGap,
                         preserveGeometry: prior?.count == localNodes.count && solution.iterations == 0)
                    ?? pack(items, gap: nodeGap,
                            aspect: presentation == .compact ? 1.8 : 1.35,
                            horizontalPositions: solution.positions)
                : pack(items, gap: nodeGap,
                       aspect: presentation == .compact ? 1.8 : 1.35,
                       horizontalPositions: solution.positions)
            regionsByGroup[piece.group, default: []].append(("piece:\(pieceIndex)", region))
        }

        var groupRegions: [String: Region] = [:]
        for group in membersByGroup.keys.sorted() {
            let children = regionsByGroup[group, default: []]
            let packed = pack(children.map { Item(id: $0.id, size: $0.region.size) },
                              gap: pieceGap, aspect: 2.2, serpentine: true)
            var points: [String: CGPoint] = [:]
            for child in children {
                let center = packed.positions[child.id]!
                for (id, point) in child.region.positions {
                    points[id] = CGPoint(x: point.x + center.x - child.region.size.width / 2,
                                         y: point.y + center.y - child.region.size.height / 2)
                }
            }
            groupRegions[group] = Region(positions: points, size: packed.size)
        }

        let orderedGroups = connectedGroupOrder(Array(groupRegions.keys), links: groupLinks)
        let packedGroups = placeCommunities(
            orderedGroups.map { Item(id: $0, size: groupRegions[$0]!.size) },
            links: groupLinks, gap: groupGap
        )
        var points: [String: CGPoint] = [:]
        for group in orderedGroups {
            let region = groupRegions[group]!
            let center = packedGroups.positions[group]!
            for (id, point) in region.positions {
                points[id] = CGPoint(
                    x: point.x + center.x - region.size.width / 2 - packedGroups.size.width / 2,
                    y: point.y + center.y - region.size.height / 2 - packedGroups.size.height / 2
                )
            }
        }
        points = avoidPins(points, sizes: sizes, pins: pins, gap: nodeGap, metrics: &metrics)
        return Result(positions: points, metrics: metrics)
    }

    private static func groups(nodes: [GraphNode], hints: [String: String], adjacency: [String: [String]]) -> [String: String] {
        var groups: [String: String] = [:]
        for node in nodes {
            if let hint = hints[node.id] { groups[node.id] = "authored:\(hint)" }
        }
        // This fallback only preserves topology. Semantic/inferred grouping is supplied
        // by the shared grouping model through the same hints API for both databases.
        for node in nodes where groups[node.id] == nil {
            if adjacency[node.id, default: []].isEmpty {
                groups[node.id] = "unassigned:isolated"
                continue
            }
            let group = "unassigned:\(node.id)"
            var queue = [node.id]
            groups[node.id] = group
            var index = 0
            while index < queue.count {
                let current = queue[index]
                index += 1
                for neighbor in adjacency[current, default: []] where groups[neighbor] == nil {
                    groups[neighbor] = group
                    queue.append(neighbor)
                }
            }
        }
        return groups
    }

    private static func connectedGroupOrder(_ groups: [String], links: [String: [String: Int]]) -> [String] {
        let degrees = links.mapValues { $0.values.reduce(0, +) }
        let roots = groups.sorted {
            degrees[$0, default: 0] == degrees[$1, default: 0]
                ? $0 < $1 : degrees[$0, default: 0] > degrees[$1, default: 0]
        }
        var result: [String] = []
        var visited: Set<String> = []
        for root in roots where visited.insert(root).inserted {
            var queue = [root]
            var index = 0
            while index < queue.count {
                let current = queue[index]
                index += 1
                result.append(current)
                let neighbors = links[current, default: [:]].sorted {
                    $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
                }
                for (neighbor, _) in neighbors where visited.insert(neighbor).inserted { queue.append(neighbor) }
            }
        }
        return result
    }

    /// Preserve the local force solution instead of flattening a community into
    /// rows. Place the best-connected card first, then move only cards whose
    /// actual rectangles collide. The search is bounded by the 48-card cutoff.
    private static func fabric(
        _ items: [Item], preferred: [String: CGPoint], gap: CGFloat,
        preserveGeometry: Bool = false
    ) -> Region? {
        guard let hub = items.first else { return Region(positions: [:], size: .zero) }
        let hubPoint = finitePosition(preferred[hub.id])
        let seeds = items.map { finitePosition(preferred[$0.id]) }
        let xSpan = max(1, (seeds.map(\.x).max() ?? 0) - (seeds.map(\.x).min() ?? 0))
        let ySpan = max(1, (seeds.map(\.y).max() ?? 0) - (seeds.map(\.y).min() ?? 0))
        let cardArea = items.reduce(CGFloat.zero) {
            $0 + ($1.size.width + gap) * ($1.size.height + gap)
        }
        // The ordinary solver may return a tall or wide strip when an authored
        // domain contains several weakly linked components. Give both axes a
        // card-area-derived span before resolving collisions; this avoids a
        // full catalog that fits only as a thin vertical column.
        let targetSpan = sqrt(cardArea) * 1.45
        let xScale = preserveGeometry ? 1 : min(2.4, max(0.12, targetSpan / xSpan))
        let yScale = preserveGeometry ? 1 : min(2.4, max(0.12, targetSpan / ySpan))
        var positions: [String: CGPoint] = [:]
        var occupied: [CGRect] = []
        for item in items {
            let seed = finitePosition(preferred[item.id])
            let desired = CGPoint(x: (seed.x - hubPoint.x) * xScale,
                                  y: (seed.y - hubPoint.y) * yScale)
            let step = max(item.size.width, item.size.height) * 0.46 + gap
            var chosen: CGPoint?
            for ring in 0...max(24, items.count) {
                let candidateCount = ring == 0 ? 1 : 18
                for index in 0..<candidateCount {
                    let angle = stableAngle(item.id) + CGFloat(index) * 2 * .pi / CGFloat(candidateCount)
                        + CGFloat(ring) * 0.37
                    let candidate = ring == 0 ? desired : CGPoint(
                        x: desired.x + cos(angle) * step * CGFloat(ring),
                        y: desired.y + sin(angle) * step * CGFloat(ring)
                    )
                    let padded = frame(candidate, item.size).insetBy(dx: -gap / 2, dy: -gap / 2)
                    if !occupied.contains(where: { $0.intersects(padded) }) {
                        chosen = candidate
                        occupied.append(padded)
                        break
                    }
                }
                if chosen != nil { break }
            }
            guard let chosen else { return nil }
            positions[item.id] = chosen
        }
        return normalizedRegion(positions, items: items)
    }

    /// A weighted community meta-graph supplies a preferred center for each
    /// domain. Linked domains gather around shared hubs, while disconnected
    /// domains use a deterministic spiral. Rectangle clearance is exact, so
    /// the layout remains readable with wide or expanded database cards.
    private static func placeCommunities(
        _ items: [Item], links: [String: [String: Int]], gap: CGFloat
    ) -> Region {
        guard !items.isEmpty else { return Region(positions: [:], size: .zero) }
        guard items.count <= 64 else { return pack(items, gap: gap, aspect: 2.2, serpentine: true) }
        var positions: [String: CGPoint] = [:]
        var occupied: [CGRect] = []
        for (index, item) in items.enumerated() {
            let neighbors = links[item.id, default: [:]].compactMap { id, count -> (CGPoint, CGFloat)? in
                guard let position = positions[id], count > 0 else { return nil }
                return (position, CGFloat(log1p(Double(count))))
            }
            let weight = neighbors.reduce(CGFloat.zero) { $0 + $1.1 }
            let preferred: CGPoint
            if index == 0 {
                preferred = .zero
            } else if weight > 0 {
                preferred = CGPoint(
                    x: neighbors.reduce(CGFloat.zero) { $0 + $1.0.x * $1.1 } / weight,
                    y: neighbors.reduce(CGFloat.zero) { $0 + $1.0.y * $1.1 } / weight
                )
            } else {
                let angle = CGFloat(index) * 2.399_963_23 + stableAngle(item.id) * 0.13
                let radius = sqrt(CGFloat(index)) * max(item.size.width, item.size.height, gap)
                preferred = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            let step = max(item.size.width, item.size.height) * 0.52 + gap
            let priorBounds = occupied.reduce(CGRect.null) { $0.union($1) }
            var best: (point: CGPoint, score: CGFloat)?
            var firstFreeRing: Int?
            for ring in 0...max(40, items.count * 3) {
                if let firstFreeRing, ring > firstFreeRing + 2 { break }
                let candidateCount = ring == 0 ? 1 : 24
                for sample in 0..<candidateCount {
                    let angle = stableAngle(item.id) + CGFloat(sample) * 2 * .pi / CGFloat(candidateCount)
                        + CGFloat(ring) * 0.19
                    let candidate = ring == 0 ? preferred : CGPoint(
                        x: preferred.x + cos(angle) * step * CGFloat(ring),
                        y: preferred.y + sin(angle) * step * CGFloat(ring)
                    )
                    let padded = frame(candidate, item.size).insetBy(dx: -gap / 2, dy: -gap / 2)
                    guard !occupied.contains(where: { $0.intersects(padded) }) else { continue }
                    if firstFreeRing == nil { firstFreeRing = ring }
                    let linkDistance = neighbors.reduce(CGFloat.zero) {
                        $0 + $1.1 * hypot(candidate.x - $1.0.x, candidate.y - $1.0.y)
                    }
                    let bounds = priorBounds.isNull ? padded : priorBounds.union(padded)
                    let aspect = max(bounds.width, 1) / max(bounds.height, 1)
                    let aspectCost = abs(log(aspect / 1.85)) * max(bounds.width, bounds.height) * 1.35
                    let score = linkDistance
                        + hypot(candidate.x - preferred.x, candidate.y - preferred.y) * 0.2
                        + aspectCost
                    if best == nil || score < best!.score { best = (candidate, score) }
                }
            }
            guard let best else { return pack(items, gap: gap, aspect: 2.2, serpentine: true) }
            positions[item.id] = best.point
            occupied.append(frame(best.point, item.size).insetBy(dx: -gap / 2, dy: -gap / 2))
        }
        return normalizedRegion(positions, items: items)
    }

    private static func normalizedRegion(_ positions: [String: CGPoint], items: [Item]) -> Region {
        let bounds = items.reduce(CGRect.null) { result, item in
            guard let position = positions[item.id] else { return result }
            return result.union(frame(position, item.size))
        }
        guard !bounds.isNull else { return Region(positions: [:], size: .zero) }
        return Region(
            positions: positions.mapValues { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) },
            size: bounds.size
        )
    }

    private static func stableAngle(_ id: String) -> CGFloat {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return CGFloat(hash % 10_000) * 2 * .pi / 10_000
    }

    /// Try a fixed number of shelf widths. Work remains linear in the item count;
    /// real rectangle sizes, rather than a fixed 410-by-74 grid, determine clearance.
    private static func pack(
        _ items: [Item], gap: CGFloat, aspect: CGFloat, serpentine: Bool = false,
        horizontalPositions: [String: CGPoint]? = nil
    ) -> Region {
        guard !items.isEmpty else { return Region(positions: [:], size: .zero) }
        let area = items.reduce(CGFloat.zero) { $0 + ($1.size.width + gap) * ($1.size.height + gap) }
        let targetWidth = sqrt(area * aspect)
        let widestItem = items.map(\.size.width).max() ?? 1
        var bestRows: [Row] = []
        var bestSize = CGSize.zero
        var bestScore = CGFloat.infinity
        for factor: CGFloat in [0.65, 0.8, 1, 1.15, 1.3, 1.5, 1.8, 2.1] {
            let widthLimit = max(widestItem, targetWidth * factor)
            var rows: [Row] = []
            var row = Row()
            for item in items {
                if !row.items.isEmpty, row.width + gap + item.size.width > widthLimit {
                    rows.append(row)
                    row = Row()
                }
                row.width += (row.items.isEmpty ? 0 : gap) + item.size.width
                row.height = max(row.height, item.size.height)
                row.items.append(item)
            }
            if !row.items.isEmpty { rows.append(row) }
            let width = rows.map(\.width).max() ?? 1
            let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + gap * CGFloat(max(rows.count - 1, 0))
            let score = width * height * (1 + 0.3 * abs(log(width / max(height, 1) / aspect)))
            if score < bestScore {
                bestScore = score
                bestRows = rows
                bestSize = CGSize(width: width, height: height)
            }
        }
        var points: [String: CGPoint] = [:]
        var y: CGFloat = 0
        for (rowIndex, row) in bestRows.enumerated() {
            let orderedItems = horizontalPositions.map { positions in
                row.items.sorted {
                    let leftX = finitePosition(positions[$0.id]).x
                    let rightX = finitePosition(positions[$1.id]).x
                    return leftX == rightX ? $0.id < $1.id : leftX < rightX
                }
            } ?? row.items
            let backwards = serpentine && !rowIndex.isMultiple(of: 2)
            var x = backwards ? (bestSize.width + row.width) / 2 : (bestSize.width - row.width) / 2
            for item in orderedItems {
                let centerX = backwards ? x - item.size.width / 2 : x + item.size.width / 2
                points[item.id] = CGPoint(x: centerX, y: y + row.height / 2)
                x += (backwards ? -1 : 1) * (item.size.width + gap)
            }
            y += row.height + gap
        }
        return Region(positions: points, size: bestSize)
    }

    static func isLegacyOverview(_ snapshot: GraphLayoutSnapshot, validIDs: Set<String>) -> Bool {
        let points = snapshot.positions.filter {
            validIDs.contains($0.key) && snapshot.pinnedPositions[$0.key] == nil && isFinite($0.value)
        }.values
        guard points.count >= 16, let origin = points.first else { return false }
        var spansColumns = false
        var spansRows = false
        for point in points {
            let column = (point.x - origin.x) / 410
            let row = (point.y - origin.y) / 74
            guard abs(column - column.rounded()) < 0.000_01,
                  abs(row - row.rounded()) < 0.000_01 else { return false }
            spansColumns = spansColumns || abs(column) >= 1
            spansRows = spansRows || abs(row) >= 1
        }
        return spansColumns && spansRows
    }

    static func isNonOverlapping(_ positions: [String: CGPoint], sizes: [String: CGSize]) -> Bool {
        var index = ObstacleIndex(sizes: sizes)
        for id in positions.keys.sorted() {
            guard let size = sizes[id], let point = positions[id], isFinite(point) else { return false }
            let rect = frame(point, size)
            var checks = 0
            guard case .free = index.firstCollision(with: rect, checks: &checks) else { return false }
            index.insert(id: id, rect: rect)
        }
        return true
    }

    private static func avoidPins(
        _ positions: [String: CGPoint], sizes: [String: CGSize], pins: [String: CGPoint],
        gap: CGFloat, metrics: inout LargeGraphLayoutMetrics
    ) -> [String: CGPoint] {
        let validPins = pins.filter { positions[$0.key] != nil && isFinite($0.value) }
        guard !validPins.isEmpty else { return positions }
        var result = positions
        var index = ObstacleIndex(sizes: sizes, gap: gap)
        var bounds = CGRect.null
        for (id, point) in positions { bounds = bounds.union(frame(point, sizes[id]!)) }
        for id in validPins.keys.sorted() {
            let point = validPins[id]!
            let rect = frame(point, sizes[id]!)
            bounds = bounds.union(rect)
            result[id] = point
            index.insert(id: id, rect: rect.insetBy(dx: -gap / 2, dy: -gap / 2))
        }

        // An overflow shelf lies wholly beyond every original card and pin. A fixed
        // obstacle-check budget therefore has a guaranteed collision-free fallback,
        // even for pathological snapshots with thousands of coincident pinned nodes.
        let limitX = bounds.maxX
        var fallbackX = limitX + gap
        var fallbackY = bounds.minY
        var fallbackColumnWidth: CGFloat = 0
        let fallbackHeight = max(bounds.height, sqrt(CGFloat(positions.count)) * 200)
        for id in positions.keys.sorted() where validPins[id] == nil {
            let size = sizes[id]!
            var point = positions[id]!
            var placed = false
            for _ in 0..<8 {
                let rect = frame(point, size).insetBy(dx: -gap / 2, dy: -gap / 2)
                switch index.firstCollision(with: rect, checks: &metrics.obstacleChecks) {
                case .free:
                    if rect.maxX <= limitX + gap / 2 {
                        result[id] = point
                        index.insert(id: id, rect: rect)
                        placed = true
                    }
                case .collision(let obstacle):
                    let movements = [
                        CGVector(dx: obstacle.maxX - rect.minX + 1, dy: 0),
                        CGVector(dx: obstacle.minX - rect.maxX - 1, dy: 0),
                        CGVector(dx: 0, dy: obstacle.maxY - rect.minY + 1),
                        CGVector(dx: 0, dy: obstacle.minY - rect.maxY - 1),
                    ]
                    let move = movements.enumerated().min {
                        let lhs = abs($0.element.dx) + abs($0.element.dy)
                        let rhs = abs($1.element.dx) + abs($1.element.dy)
                        return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                    }!.element
                    point.x += move.dx
                    point.y += move.dy
                case .saturated:
                    break
                }
                if placed { break }
            }
            if !placed {
                if fallbackY > bounds.minY, fallbackY + size.height > bounds.minY + fallbackHeight {
                    fallbackX += fallbackColumnWidth + gap
                    fallbackY = bounds.minY
                    fallbackColumnWidth = 0
                }
                result[id] = CGPoint(x: fallbackX + size.width / 2, y: fallbackY + size.height / 2)
                fallbackY += size.height + gap
                fallbackColumnWidth = max(fallbackColumnWidth, size.width)
            }
        }
        return result
    }

    private struct ObstacleIndex {
        struct Cell: Hashable { let x: Int; let y: Int }
        struct Entry { let id: String; let rect: CGRect }
        enum Query { case free, collision(CGRect), saturated }
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        var entries: [Cell: [Entry]] = [:]

        init(sizes: [String: CGSize], gap: CGFloat = 0) {
            cellWidth = max(1, (sizes.values.map(\.width).max() ?? 1) + gap)
            cellHeight = max(1, (sizes.values.map(\.height).max() ?? 1) + gap)
        }

        private func cells(for rect: CGRect) -> [Cell] {
            func coordinate(_ value: CGFloat) -> Int {
                Int(min(CGFloat(Int.max / 4), max(CGFloat(Int.min / 4), floor(value))))
            }
            let minX = coordinate(rect.minX / cellWidth)
            let maxX = coordinate(rect.maxX / cellWidth)
            let minY = coordinate(rect.minY / cellHeight)
            let maxY = coordinate(rect.maxY / cellHeight)
            return (minX...maxX).flatMap { x in (minY...maxY).map { Cell(x: x, y: $0) } }
        }

        mutating func insert(id: String, rect: CGRect) {
            for cell in cells(for: rect) { entries[cell, default: []].append(Entry(id: id, rect: rect)) }
        }

        func firstCollision(with rect: CGRect, checks: inout Int) -> Query {
            var visited: Set<String> = []
            for cell in cells(for: rect) {
                for entry in entries[cell, default: []] where visited.insert(entry.id).inserted {
                    guard visited.count <= maximumLocalNodeCount else { return .saturated }
                    checks += 1
                    if rect.intersects(entry.rect) { return .collision(entry.rect) }
                }
            }
            return .free
        }
    }

    private static func edgeOrder(_ lhs: GraphEdge, _ rhs: GraphEdge) -> Bool {
        if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
        if lhs.targetID != rhs.targetID { return lhs.targetID < rhs.targetID }
        if lhs.sourceColumn != rhs.sourceColumn { return lhs.sourceColumn < rhs.sourceColumn }
        if lhs.targetColumn != rhs.targetColumn { return lhs.targetColumn < rhs.targetColumn }
        return lhs.id < rhs.id
    }

    static func isFinite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private static func finitePosition(_ point: CGPoint?) -> CGPoint {
        guard let point, isFinite(point) else { return .zero }
        return point
    }
    private static func frame(_ center: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
               width: size.width, height: size.height)
    }
}
