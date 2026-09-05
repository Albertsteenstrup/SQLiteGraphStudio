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

/// A hierarchy around the ordinary force solver. Physics orders small connected
/// pieces; rectangle packing gives every card clearance and keeps authored groups
/// separate. Every pairwise operation is confined to a piece of at most 64 nodes.
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
            let region = pack(
                orderedIDs.map { Item(id: $0, size: sizes[$0]!) },
                gap: nodeGap,
                aspect: presentation == .compact ? 1.8 : 1.35,
                horizontalPositions: solution.positions
            )
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
        let packedGroups = pack(orderedGroups.map { Item(id: $0, size: groupRegions[$0]!.size) },
                                gap: groupGap, aspect: 2.2, serpentine: true)
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
