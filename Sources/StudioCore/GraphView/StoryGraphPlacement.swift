import SwiftUI

public enum StoryGraphCardLayout {
    public static let width: CGFloat = 190
    public static let height: CGFloat = 78
}

public struct StoryGraphPlacedCard: Identifiable, Sendable {
    public let story: SchemaSidecar.Story
    public let tableIDs: [String]
    public let primaryTableIDs: [String]
    public let clusterLabel: String?
    public let graphPosition: CGPoint

    public var id: String { story.id }

    public init(
        story: SchemaSidecar.Story,
        tableIDs: [String],
        primaryTableIDs: [String],
        clusterLabel: String?,
        graphPosition: CGPoint
    ) {
        self.story = story
        self.tableIDs = tableIDs
        self.primaryTableIDs = primaryTableIDs
        self.clusterLabel = clusterLabel
        self.graphPosition = graphPosition
    }
}

@MainActor
public enum StoryGraphPlacement {
    public static func placedCards(for session: AppSession) -> [StoryGraphPlacedCard] {
        guard session.showStoryCardsInGraph, !session.stories.isEmpty else { return [] }

        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        let seeds: [Seed] = session.stories.compactMap { story in
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

        guard !seeds.isEmpty else { return [] }

        let orderedSeeds = seeds.sorted { lhs, rhs in
            if lhs.clusterKey == rhs.clusterKey {
                return lhs.story.title.localizedStandardCompare(rhs.story.title) == .orderedAscending
            }
            return lhs.clusterKey.localizedStandardCompare(rhs.clusterKey) == .orderedAscending
        }
        let countsByCluster = Dictionary(grouping: orderedSeeds, by: \.clusterKey).mapValues(\.count)
        var nextIndexByCluster: [String: Int] = [:]

        return orderedSeeds.map { seed in
            let index = nextIndexByCluster[seed.clusterKey, default: 0]
            nextIndexByCluster[seed.clusterKey] = index + 1

            let clusterAnchorTableIDs = seed.clusterCoverage?.tableIDs.filter { graphTableIDs.contains($0) } ?? []
            let anchorTableIDs: [String]
            if !clusterAnchorTableIDs.isEmpty {
                anchorTableIDs = clusterAnchorTableIDs
            } else if !seed.primaryTableIDs.isEmpty {
                anchorTableIDs = seed.primaryTableIDs
            } else {
                anchorTableIDs = seed.tableIDs
            }
            let centroid = averageGraphPosition(for: anchorTableIDs, session: session)
            let position = storyGraphPosition(
                centroid: centroid,
                clusterKey: seed.clusterKey,
                index: index,
                count: countsByCluster[seed.clusterKey, default: 1]
            )

            return StoryGraphPlacedCard(
                story: seed.story,
                tableIDs: seed.tableIDs,
                primaryTableIDs: Array(seed.primaryTableIDs.prefix(4)),
                clusterLabel: seed.clusterCoverage?.displayLabel,
                graphPosition: position
            )
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

    private struct Seed {
        let story: SchemaSidecar.Story
        let tableIDs: [String]
        let primaryTableIDs: [String]
        let clusterCoverage: SchemaSidecar.StoryClusterCoverage?
        let clusterKey: String
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

    private static func storyGraphPosition(centroid: CGPoint, clusterKey: String, index: Int, count: Int) -> CGPoint {
        var direction = CGVector(dx: centroid.x, dy: centroid.y)
        let length = hypot(direction.dx, direction.dy)
        if length < 10 {
            let angle = stableStoryAngle(for: clusterKey)
            direction = CGVector(dx: cos(angle), dy: sin(angle))
        } else {
            direction = CGVector(dx: direction.dx / length, dy: direction.dy / length)
        }

        let tangent = CGVector(dx: -direction.dy, dy: direction.dx)
        let slotsPerBand = 5
        let slot = index % slotsPerBand
        let band = index / slotsPerBand
        let slotsInCurrentBand = min(slotsPerBand, max(count - band * slotsPerBand, 1))
        let centeredSlot = CGFloat(slot) - CGFloat(slotsInCurrentBand - 1) / 2
        let radialDistance: CGFloat = 118 + CGFloat(band) * 92
        let tangentDistance: CGFloat = centeredSlot * 130

        return CGPoint(
            x: centroid.x + direction.dx * radialDistance + tangent.dx * tangentDistance,
            y: centroid.y + direction.dy * radialDistance + tangent.dy * tangentDistance
        )
    }

    private static func stableStoryAngle(for key: String) -> CGFloat {
        let value = key.unicodeScalars.reduce(UInt32(2166136261)) { partial, scalar in
            (partial ^ scalar.value) &* 16777619
        }
        return CGFloat(value % 360) * .pi / 180
    }
}
