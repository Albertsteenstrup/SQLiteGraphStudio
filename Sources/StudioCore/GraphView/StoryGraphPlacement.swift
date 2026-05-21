import SwiftUI

public enum StoryGraphCardLayout {
    public static let width: CGFloat = 190
    public static let height: CGFloat = 78
}

public enum StoryGraphLayoutDensity: Sendable, Equatable {
    /// Few enough stories to fit entirely in the viewport with readable cluster labels.
    case fitAll
    /// Crowded story-only view — tighter spacing and smaller cluster titles.
    case compact
}

public enum StoryGraphLayoutMode: Sendable, Equatable {
    case anchoredToTables
    case dedicated(StoryGraphLayoutDensity)

    public var persistenceKey: String {
        switch self {
        case .anchoredToTables:
            return "anchored"
        case .dedicated:
            return "dedicated"
        }
    }
}

public struct StoryGraphPlacedCard: Identifiable, Sendable {
    public let story: SchemaSidecar.Story
    public let tableIDs: [String]
    public let primaryTableIDs: [String]
    public let clusterKey: String
    public let clusterLabel: String?
    public let clusterColorHex: String?
    public let graphPosition: CGPoint

    public var id: String { story.id }

    public init(
        story: SchemaSidecar.Story,
        tableIDs: [String],
        primaryTableIDs: [String],
        clusterKey: String,
        clusterLabel: String?,
        clusterColorHex: String?,
        graphPosition: CGPoint
    ) {
        self.story = story
        self.tableIDs = tableIDs
        self.primaryTableIDs = primaryTableIDs
        self.clusterKey = clusterKey
        self.clusterLabel = clusterLabel
        self.clusterColorHex = clusterColorHex
        self.graphPosition = graphPosition
    }
}

@MainActor
public enum StoryGraphPlacement {
    public static let crowdedStoryThreshold = GraphLayoutModel.crowdedNodeThreshold

    public static func layoutMode(for session: AppSession) -> StoryGraphLayoutMode {
        guard session.showStoryCardsInGraph else { return .anchoredToTables }
        guard session.showOnlyStoryCardsInGraph else { return .anchoredToTables }
        let count = placeableStoryCount(for: session)
        guard count > 0 else { return .anchoredToTables }
        let density: StoryGraphLayoutDensity = count < crowdedStoryThreshold ? .fitAll : .compact
        return .dedicated(density)
    }

    public static func placeableStoryCount(for session: AppSession) -> Int {
        guard session.showStoryCardsInGraph, !session.stories.isEmpty else { return 0 }
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        return session.stories.filter { story in
            story.coveredTableIDs.contains { graphTableIDs.contains($0) }
        }.count
    }

    public static func placedCards(for session: AppSession) -> [StoryGraphPlacedCard] {
        let seeds = makeSeeds(for: session)
        guard !seeds.isEmpty else { return [] }

        let layoutMode = layoutMode(for: session)
        let orderedSeeds = seeds.sorted { lhs, rhs in
            if lhs.clusterKey == rhs.clusterKey {
                return lhs.story.title.localizedStandardCompare(rhs.story.title) == .orderedAscending
            }
            return lhs.clusterKey.localizedStandardCompare(rhs.clusterKey) == .orderedAscending
        }

        switch layoutMode {
        case .anchoredToTables:
            return anchoredPlacedCards(from: orderedSeeds, session: session)
        case .dedicated(let density):
            return dedicatedPlacedCards(from: orderedSeeds, density: density)
        }
    }

    public static func contentBounds(
        for cards: [StoryGraphPlacedCard],
        positionLookup: (StoryGraphPlacedCard) -> CGPoint = { $0.graphPosition }
    ) -> CGRect {
        guard !cards.isEmpty else { return .zero }

        var bounds = CGRect.zero
        for card in cards {
            let graphPoint = positionLookup(card)
            let frame = CGRect(
                x: graphPoint.x - StoryGraphCardLayout.width / 2,
                y: graphPoint.y - StoryGraphCardLayout.height / 2,
                width: StoryGraphCardLayout.width,
                height: StoryGraphCardLayout.height
            )
            bounds = bounds.isEmpty ? frame : bounds.union(frame)
        }
        return bounds
    }

    public static func clusterTitleStyle(for session: AppSession) -> (fontSize: CGFloat, padding: CGFloat) {
        switch layoutMode(for: session) {
        case .dedicated(.compact):
            return (11, 14)
        case .dedicated(.fitAll):
            return (14, 20)
        case .anchoredToTables:
            return (15, 22)
        }
    }

    static func cardFrame(at center: CGPoint, padding: CGFloat = 0) -> CGRect {
        CGRect(
            x: center.x - StoryGraphCardLayout.width / 2 - padding,
            y: center.y - StoryGraphCardLayout.height / 2 - padding,
            width: StoryGraphCardLayout.width + padding * 2,
            height: StoryGraphCardLayout.height + padding * 2
        )
    }

    private static let storyCardSize = CGSize(
        width: StoryGraphCardLayout.width,
        height: StoryGraphCardLayout.height
    )
    private static let storyCollisionGap: CGFloat = 22

    // MARK: - Seeds

    private struct Seed {
        let story: SchemaSidecar.Story
        let tableIDs: [String]
        let primaryTableIDs: [String]
        let clusterCoverage: SchemaSidecar.StoryClusterCoverage?
        let clusterKey: String
    }

    private static func makeSeeds(for session: AppSession) -> [Seed] {
        guard session.showStoryCardsInGraph, !session.stories.isEmpty else { return [] }

        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        return session.stories.compactMap { story in
            let tableIDs = story.coveredTableIDs.filter { graphTableIDs.contains($0) }
            guard !tableIDs.isEmpty else { return nil }

            let primaryTableIDs = story.primaryTableIDs.filter { graphTableIDs.contains($0) }
            let primaryCluster = session.schemaSidecar.primaryClusterCoverage(for: story)
            let clusterKey = primaryCluster?.clusterID ?? "schema"
            return Seed(
                story: story,
                tableIDs: tableIDs,
                primaryTableIDs: primaryTableIDs.isEmpty ? Array(tableIDs.prefix(3)) : primaryTableIDs,
                clusterCoverage: primaryCluster,
                clusterKey: clusterKey
            )
        }
    }

    // MARK: - Anchored layout (stories beside schema tables)

    private static func anchoredPlacedCards(from orderedSeeds: [Seed], session: AppSession) -> [StoryGraphPlacedCard] {
        let grouped = Dictionary(grouping: orderedSeeds, by: \.clusterKey)
        let clusterCentroids = clusterTableCentroids(for: session)
        let spacing = anchoredSpacing()
        let titleStyle = clusterTitleStyle(for: session)
        let clusterReserves = clusterReserveFrames(for: session, titleStyle: titleStyle)
        let tableObstacles = tableObstacleFrames(for: session, haloPadding: titleStyle.padding)

        var positions: [String: CGPoint] = [:]
        for seed in orderedSeeds {
            let clusterStories = grouped[seed.clusterKey] ?? [seed]
            let index = clusterStories.firstIndex(where: { $0.story.id == seed.story.id }) ?? 0
            let count = clusterStories.count
            let centroid = clusterCentroids[seed.clusterKey]
                ?? fallbackClusterCentroid(for: seed, session: session)
            let ownReserve = clusterReserves[seed.clusterKey]
            let otherObstacles = tableObstacles + clusterReserves
                .filter { $0.key != seed.clusterKey }
                .map(\.value)
            positions[seed.story.id] = anchoredClusterStoryPosition(
                clusterCentroid: centroid,
                clusterKey: seed.clusterKey,
                index: index,
                count: count,
                spacing: spacing,
                ownReserve: ownReserve,
                otherObstacles: otherObstacles
            )
        }

        resolveStoryCollisions(
            positions: &positions,
            staticObstacles: tableObstacles + clusterReserves.values.map { $0 },
            gap: storyCollisionGap
        )

        resolveClusterGroupCollisions(
            positions: &positions,
            grouped: grouped,
            titleStyle: titleStyle,
            gap: storyCollisionGap + 28
        )

        return orderedSeeds.map { seed in
            makePlacedCard(from: seed, position: positions[seed.story.id] ?? .zero)
        }
    }

    private static func clusterTableCentroids(for session: AppSession) -> [String: CGPoint] {
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        var centroids: [String: CGPoint] = [:]

        for cluster in session.schemaSidecar.clusters {
            let tables = cluster.tables.filter { graphTableIDs.contains($0) }
            guard !tables.isEmpty else { continue }
            centroids[cluster.id] = averageGraphPosition(for: tables, session: session)
        }

        return centroids
    }

    private static func fallbackClusterCentroid(for seed: Seed, session: AppSession) -> CGPoint {
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        let clusterAnchorTableIDs = seed.clusterCoverage?.tableIDs.filter { graphTableIDs.contains($0) } ?? []
        let anchorTableIDs: [String]
        if !clusterAnchorTableIDs.isEmpty {
            anchorTableIDs = clusterAnchorTableIDs
        } else if !seed.primaryTableIDs.isEmpty {
            anchorTableIDs = seed.primaryTableIDs
        } else {
            anchorTableIDs = seed.tableIDs
        }
        return averageGraphPosition(for: anchorTableIDs, session: session)
    }

    private static func anchoredSpacing() -> DedicatedSpacing {
        DedicatedSpacing(horizontalGap: 24, verticalGap: 18, clusterRingBase: 0, clusterRingPerStory: 0)
    }

    private static func anchoredClusterStoryPosition(
        clusterCentroid: CGPoint,
        clusterKey: String,
        index: Int,
        count: Int,
        spacing: DedicatedSpacing,
        ownReserve: CGRect?,
        otherObstacles: [CGRect]
    ) -> CGPoint {
        let gridLocal = dedicatedStoryPosition(
            clusterCenter: .zero,
            index: index,
            count: count,
            spacing: spacing
        )
        let gridHalfWidth = gridSpan(for: count, spacing: spacing).width / 2
        let gridHalfHeight = gridSpan(for: count, spacing: spacing).height / 2

        let baseAngle = outwardAngle(for: clusterCentroid, clusterKey: clusterKey)
        let placement = bestOutwardPlacement(
            centroid: clusterCentroid,
            baseAngle: baseAngle,
            gridHalfWidth: gridHalfWidth,
            gridHalfHeight: gridHalfHeight,
            ownReserve: ownReserve,
            otherObstacles: otherObstacles,
            gap: storyCollisionGap
        )

        return CGPoint(
            x: placement.center.x + gridLocal.x,
            y: placement.center.y + gridLocal.y
        )
    }

    private static func gridSpan(for count: Int, spacing: DedicatedSpacing) -> CGSize {
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        return CGSize(
            width: CGFloat(columns) * StoryGraphCardLayout.width
                + CGFloat(max(columns - 1, 0)) * spacing.horizontalGap,
            height: CGFloat(rows) * StoryGraphCardLayout.height
                + CGFloat(max(rows - 1, 0)) * spacing.verticalGap
        )
    }

    private static func outwardAngle(for centroid: CGPoint, clusterKey: String) -> CGFloat {
        let length = hypot(centroid.x, centroid.y)
        if length < 10 {
            return stableStoryAngle(for: clusterKey)
        }
        return atan2(centroid.y, centroid.x)
    }

    private struct OutwardPlacement {
        let center: CGPoint
        let distance: CGFloat
    }

    private static func bestOutwardPlacement(
        centroid: CGPoint,
        baseAngle: CGFloat,
        gridHalfWidth: CGFloat,
        gridHalfHeight: CGFloat,
        ownReserve: CGRect?,
        otherObstacles: [CGRect],
        gap: CGFloat
    ) -> OutwardPlacement {
        var best: OutwardPlacement?

        for step in 0..<8 {
            let angle = baseAngle + CGFloat(step) * (.pi / 4)
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            var distance = outwardDistanceClearing(
                centroid: centroid,
                direction: direction,
                gridHalfWidth: gridHalfWidth,
                gridHalfHeight: gridHalfHeight,
                reserve: ownReserve,
                gap: gap
            )
            var center = CGPoint(
                x: centroid.x + direction.dx * distance,
                y: centroid.y + direction.dy * distance
            )
            while frameIntersectsAny(
                gridFrame(center: center, halfWidth: gridHalfWidth, halfHeight: gridHalfHeight, gap: gap),
                obstacles: otherObstacles
            ), distance < 2_400 {
                distance += 20
                center = CGPoint(
                    x: centroid.x + direction.dx * distance,
                    y: centroid.y + direction.dy * distance
                )
            }

            let candidate = OutwardPlacement(center: center, distance: distance)
            if best == nil || candidate.distance < best!.distance {
                best = candidate
            }
        }

        return best ?? OutwardPlacement(center: centroid, distance: 180)
    }

    private static func outwardDistanceClearing(
        centroid: CGPoint,
        direction: CGVector,
        gridHalfWidth: CGFloat,
        gridHalfHeight: CGFloat,
        reserve: CGRect?,
        gap: CGFloat
    ) -> CGFloat {
        guard let reserve, !reserve.isNull else { return 180 + max(gridHalfWidth, gridHalfHeight) }

        var distance: CGFloat = 0
        for _ in 0..<120 {
            let center = CGPoint(
                x: centroid.x + direction.dx * distance,
                y: centroid.y + direction.dy * distance
            )
            let grid = gridFrame(
                center: center,
                halfWidth: gridHalfWidth,
                halfHeight: gridHalfHeight,
                gap: gap
            )
            if !grid.intersects(reserve) {
                return distance
            }
            distance += 16
        }
        return distance
    }

    private static func gridFrame(
        center: CGPoint,
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        gap: CGFloat
    ) -> CGRect {
        CGRect(
            x: center.x - halfWidth - gap,
            y: center.y - halfHeight - gap,
            width: (halfWidth + gap) * 2,
            height: (halfHeight + gap) * 2
        )
    }

    // MARK: - Dedicated story-only layout

    private static func dedicatedPlacedCards(
        from orderedSeeds: [Seed],
        density: StoryGraphLayoutDensity
    ) -> [StoryGraphPlacedCard] {
        let grouped = Dictionary(grouping: orderedSeeds, by: \.clusterKey)
        let clusterKeys = grouped.keys.sorted()
        let clusterCount = max(clusterKeys.count, 1)
        let spacing = dedicatedSpacing(for: density)

        var clusterCenters: [String: CGPoint] = [:]
        if clusterCount == 1, let onlyKey = clusterKeys.first {
            clusterCenters[onlyKey] = .zero
        } else {
            let ringRadius = dedicatedClusterRingRadius(
                clusterCount: clusterCount,
                maxStoriesInCluster: grouped.values.map(\.count).max() ?? 1,
                spacing: spacing
            )
            for (clusterIndex, clusterKey) in clusterKeys.enumerated() {
                let angle = Double(clusterIndex) * (2 * .pi / Double(clusterCount))
                clusterCenters[clusterKey] = CGPoint(
                    x: cos(angle) * ringRadius,
                    y: sin(angle) * ringRadius
                )
            }
        }

        var positions: [String: CGPoint] = [:]
        for seed in orderedSeeds {
            let clusterStories = grouped[seed.clusterKey] ?? [seed]
            let index = clusterStories.firstIndex(where: { $0.story.id == seed.story.id }) ?? 0
            let count = clusterStories.count
            let center = clusterCenters[seed.clusterKey] ?? .zero
            positions[seed.story.id] = dedicatedStoryPosition(
                clusterCenter: center,
                index: index,
                count: count,
                spacing: spacing
            )
        }

        resolveClusterGroupCollisions(
            positions: &positions,
            grouped: grouped,
            titleStyle: (fontSize: 14, padding: 20),
            gap: storyCollisionGap + 36
        )

        return orderedSeeds.map { seed in
            makePlacedCard(from: seed, position: positions[seed.story.id] ?? .zero)
        }
    }

    private struct DedicatedSpacing {
        let horizontalGap: CGFloat
        let verticalGap: CGFloat
        let clusterRingBase: CGFloat
        let clusterRingPerStory: CGFloat
    }

    private static func dedicatedSpacing(for density: StoryGraphLayoutDensity) -> DedicatedSpacing {
        switch density {
        case .fitAll:
            return DedicatedSpacing(horizontalGap: 28, verticalGap: 22, clusterRingBase: 200, clusterRingPerStory: 18)
        case .compact:
            return DedicatedSpacing(horizontalGap: 14, verticalGap: 12, clusterRingBase: 130, clusterRingPerStory: 10)
        }
    }

    private static func dedicatedClusterRingRadius(
        clusterCount: Int,
        maxStoriesInCluster: Int,
        spacing: DedicatedSpacing
    ) -> CGFloat {
        let cols = max(1, Int(ceil(sqrt(Double(maxStoriesInCluster)))))
        let rows = max(1, Int(ceil(Double(maxStoriesInCluster) / Double(cols))))
        let clusterFootprint = max(
            CGFloat(cols) * StoryGraphCardLayout.width + CGFloat(cols - 1) * spacing.horizontalGap,
            CGFloat(rows) * StoryGraphCardLayout.height + CGFloat(rows - 1) * spacing.verticalGap
        )
        let perClusterReach = clusterFootprint / 2
            + spacing.clusterRingPerStory * CGFloat(maxStoriesInCluster)
            + 56
        let minRing = spacing.clusterRingBase + perClusterReach
        guard clusterCount > 1 else { return 0 }
        let safeSin = max(sin(.pi / Double(clusterCount)), 0.2)
        return max(minRing, perClusterReach * 1.6 / CGFloat(safeSin))
    }

    private static func dedicatedStoryPosition(
        clusterCenter: CGPoint,
        index: Int,
        count: Int,
        spacing: DedicatedSpacing
    ) -> CGPoint {
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let row = index / columns
        let column = index % columns
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))

        let gridWidth = CGFloat(columns) * StoryGraphCardLayout.width
            + CGFloat(max(columns - 1, 0)) * spacing.horizontalGap
        let gridHeight = CGFloat(rows) * StoryGraphCardLayout.height
            + CGFloat(max(rows - 1, 0)) * spacing.verticalGap

        let originX = clusterCenter.x - gridWidth / 2 + StoryGraphCardLayout.width / 2
        let originY = clusterCenter.y - gridHeight / 2 + StoryGraphCardLayout.height / 2

        return CGPoint(
            x: originX + CGFloat(column) * (StoryGraphCardLayout.width + spacing.horizontalGap),
            y: originY + CGFloat(row) * (StoryGraphCardLayout.height + spacing.verticalGap)
        )
    }

    // MARK: - Collision avoidance

    private static func tableObstacleFrames(for session: AppSession, haloPadding: CGFloat) -> [CGRect] {
        session.graph.nodes.map { node in
            tableNodeFrame(tableID: node.id, session: session, haloPadding: haloPadding)
        }
    }

    private static func tableNodeFrame(tableID: String, session: AppSession, haloPadding: CGFloat) -> CGRect {
        let center = session.graphLayout.position(for: tableID)
        let descriptor = session.descriptor(named: tableID)
        let title = descriptor?.name ?? tableID
        let size = GraphCardLayout.nodeSize(
            title: title,
            descriptor: descriptor,
            style: .collapsed
        )
        return CGRect(
            x: center.x - size.width / 2 - haloPadding,
            y: center.y - size.height / 2 - haloPadding,
            width: size.width + haloPadding * 2,
            height: size.height + haloPadding * 2
        )
    }

    private static func clusterReserveFrames(
        for session: AppSession,
        titleStyle: (fontSize: CGFloat, padding: CGFloat)
    ) -> [String: CGRect] {
        var reserves: [String: CGRect] = [:]
        for cluster in session.schemaSidecar.clusters {
            if let frame = clusterReserveFrame(
                for: cluster,
                session: session,
                haloPadding: titleStyle.padding,
                titleFontSize: titleStyle.fontSize
            ) {
                reserves[cluster.id] = frame
            }
        }
        return reserves
    }

    private static func clusterReserveFrame(
        for cluster: SchemaSidecar.ClusterHint,
        session: AppSession,
        haloPadding: CGFloat,
        titleFontSize: CGFloat
    ) -> CGRect? {
        var bounds: CGRect?
        for name in cluster.tables {
            guard session.graph.contains(nodeID: name) else { continue }
            let frame = tableNodeFrame(tableID: name, session: session, haloPadding: haloPadding)
            bounds = bounds.map { $0.union(frame) } ?? frame
        }
        guard var clusterBounds = bounds else { return nil }

        let titleBandHeight = titleFontSize + 36
        let titleBand = CGRect(
            x: clusterBounds.midX - clusterBounds.width / 2 - 28,
            y: clusterBounds.minY - titleBandHeight,
            width: clusterBounds.width + 56,
            height: titleBandHeight
        )
        clusterBounds = clusterBounds.union(titleBand)
        return clusterBounds
    }

    private static func frameIntersectsAny(_ frame: CGRect, obstacles: [CGRect]) -> Bool {
        obstacles.contains { $0.intersects(frame) }
    }

    private static func clusterGroupFrame(
        for clusterKey: String,
        seeds: [Seed],
        positions: [String: CGPoint],
        titleFontSize: CGFloat,
        padding: CGFloat
    ) -> CGRect? {
        let storyIDs = seeds.filter { $0.clusterKey == clusterKey }.map(\.story.id)
        var bounds: CGRect?
        for id in storyIDs {
            guard let center = positions[id] else { continue }
            let frame = cardFrame(at: center, padding: padding)
            bounds = bounds.map { $0.union(frame) } ?? frame
        }
        guard var clusterBounds = bounds else { return nil }

        let titleBandHeight = titleFontSize + 36
        let titleBand = CGRect(
            x: clusterBounds.midX - clusterBounds.width / 2 - 28,
            y: clusterBounds.minY - titleBandHeight,
            width: clusterBounds.width + 56,
            height: titleBandHeight
        )
        clusterBounds = clusterBounds.union(titleBand)
        return clusterBounds
    }

    private static func translateClusterStories(
        clusterKey: String,
        seeds: [Seed],
        positions: inout [String: CGPoint],
        by delta: CGVector
    ) {
        for seed in seeds where seed.clusterKey == clusterKey {
            guard let point = positions[seed.story.id] else { continue }
            positions[seed.story.id] = CGPoint(x: point.x + delta.dx, y: point.y + delta.dy)
        }
    }

    private static func resolveClusterGroupCollisions(
        positions: inout [String: CGPoint],
        grouped: [String: [Seed]],
        titleStyle: (fontSize: CGFloat, padding: CGFloat),
        gap: CGFloat
    ) {
        let allSeeds = grouped.values.flatMap { $0 }
        let clusterKeys = grouped.keys.sorted()
        guard clusterKeys.count > 1 else { return }

        for _ in 0..<64 {
            var moved = false

            for i in 0..<clusterKeys.count {
                for j in (i + 1)..<clusterKeys.count {
                    let leftKey = clusterKeys[i]
                    let rightKey = clusterKeys[j]
                    guard var leftFrame = clusterGroupFrame(
                        for: leftKey,
                        seeds: allSeeds,
                        positions: positions,
                        titleFontSize: titleStyle.fontSize,
                        padding: titleStyle.padding
                    ), var rightFrame = clusterGroupFrame(
                        for: rightKey,
                        seeds: allSeeds,
                        positions: positions,
                        titleFontSize: titleStyle.fontSize,
                        padding: titleStyle.padding
                    ) else {
                        continue
                    }

                    leftFrame = leftFrame.insetBy(dx: -gap / 2, dy: -gap / 2)
                    rightFrame = rightFrame.insetBy(dx: -gap / 2, dy: -gap / 2)
                    guard leftFrame.intersects(rightFrame) else { continue }

                    let dx = rightFrame.midX - leftFrame.midX
                    let dy = rightFrame.midY - leftFrame.midY
                    let overlapX = (leftFrame.width + rightFrame.width) / 2 - abs(dx)
                    let overlapY = (leftFrame.height + rightFrame.height) / 2 - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }

                    let push: CGVector
                    if overlapX < overlapY {
                        let amount = overlapX / 2 * (dx >= 0 ? 1 : -1)
                        push = CGVector(dx: amount, dy: 0)
                    } else {
                        let amount = overlapY / 2 * (dy >= 0 ? 1 : -1)
                        push = CGVector(dx: 0, dy: amount)
                    }

                    translateClusterStories(
                        clusterKey: leftKey,
                        seeds: allSeeds,
                        positions: &positions,
                        by: CGVector(dx: -push.dx, dy: -push.dy)
                    )
                    translateClusterStories(
                        clusterKey: rightKey,
                        seeds: allSeeds,
                        positions: &positions,
                        by: push
                    )
                    moved = true
                }
            }

            if !moved { break }
        }
    }

    private static func resolveStoryCollisions(
        positions: inout [String: CGPoint],
        staticObstacles: [CGRect],
        gap: CGFloat
    ) {
        let ids = Array(positions.keys)
        guard !ids.isEmpty else { return }

        for _ in 0..<64 {
            var moved = false

            for id in ids {
                guard var point = positions[id] else { continue }
                if pushAwayFromObstacles(
                    point: &point,
                    size: storyCardSize,
                    obstacles: staticObstacles,
                    gap: gap
                ) {
                    positions[id] = point
                    moved = true
                }
            }

            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let lhsID = ids[i]
                    let rhsID = ids[j]
                    guard var left = positions[lhsID], var right = positions[rhsID] else { continue }
                    if separateStoryCards(
                        lhs: &left,
                        rhs: &right,
                        gap: gap
                    ) {
                        positions[lhsID] = left
                        positions[rhsID] = right
                        moved = true
                    }
                }
            }

            if !moved { break }
        }
    }

    private static func pushAwayFromObstacles(
        point: inout CGPoint,
        size: CGSize,
        obstacles: [CGRect],
        gap: CGFloat
    ) -> Bool {
        var moved = false
        for obstacle in obstacles {
            if pushAwayFromObstacle(point: &point, size: size, obstacle: obstacle, gap: gap) {
                moved = true
            }
        }
        return moved
    }

    private static func pushAwayFromObstacle(
        point: inout CGPoint,
        size: CGSize,
        obstacle: CGRect,
        gap: CGFloat
    ) -> Bool {
        let frame = cardFrame(at: point, padding: gap)
        guard frame.intersects(obstacle) else { return false }

        let dx = point.x - obstacle.midX
        let dy = point.y - obstacle.midY
        let pushX = (frame.width + obstacle.width) / 2 - abs(dx)
        let pushY = (frame.height + obstacle.height) / 2 - abs(dy)
        guard pushX > 0, pushY > 0 else { return false }

        if pushX < pushY {
            point.x += pushX * (dx >= 0 ? 1 : -1)
        } else {
            point.y += pushY * (dy >= 0 ? 1 : -1)
        }
        return true
    }

    private static func separateStoryCards(
        lhs: inout CGPoint,
        rhs: inout CGPoint,
        gap: CGFloat
    ) -> Bool {
        let dx = rhs.x - lhs.x
        let dy = rhs.y - lhs.y
        let minDistX = storyCardSize.width + gap
        let minDistY = storyCardSize.height + gap
        let overlapX = minDistX - abs(dx)
        let overlapY = minDistY - abs(dy)
        guard overlapX > 0, overlapY > 0 else { return false }

        if overlapX < overlapY {
            let push = overlapX / 2 * (dx >= 0 ? 1 : -1)
            lhs.x -= push
            rhs.x += push
        } else {
            let push = overlapY / 2 * (dy >= 0 ? 1 : -1)
            lhs.y -= push
            rhs.y += push
        }
        return true
    }

    // MARK: - Shared helpers

    private static func makePlacedCard(from seed: Seed, position: CGPoint) -> StoryGraphPlacedCard {
        StoryGraphPlacedCard(
            story: seed.story,
            tableIDs: seed.tableIDs,
            primaryTableIDs: Array(seed.primaryTableIDs.prefix(4)),
            clusterKey: seed.clusterKey,
            clusterLabel: seed.clusterCoverage?.displayLabel,
            clusterColorHex: seed.clusterCoverage?.color,
            graphPosition: position
        )
    }

    private static func averageGraphPosition(for tableIDs: [String], session: AppSession) -> CGPoint {
        guard !tableIDs.isEmpty else { return .zero }

        let sum = tableIDs.reduce(CGPoint.zero) { partial, tableID in
            let point = session.graphLayout.position(for: tableID)
            return CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }

        return CGPoint(
            x: sum.x / CGFloat(tableIDs.count),
            y: sum.y / CGFloat(tableIDs.count)
        )
    }

    private static func stableStoryAngle(for key: String) -> CGFloat {
        let value = key.unicodeScalars.reduce(UInt32(2166136261)) { partial, scalar in
            (partial ^ scalar.value) &* 16777619
        }
        return CGFloat(value % 360) * .pi / 180
    }
}
