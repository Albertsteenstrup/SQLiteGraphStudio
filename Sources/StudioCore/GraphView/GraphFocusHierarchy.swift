import CoreGraphics

enum GraphFocusTier: Sendable, Equatable {
    case hidden
    case related
    case active
}

struct GraphFocusPlan: Sendable, Equatable {
    let activeStoryIDs: Set<String>
    let relatedStoryIDs: Set<String>
    let activeTableIDs: Set<String>
    let relatedTableIDs: Set<String>

    var isActive: Bool {
        !activeStoryIDs.isEmpty || !activeTableIDs.isEmpty
    }

    func tierForStory(_ id: String) -> GraphFocusTier {
        if activeStoryIDs.contains(id) { return .active }
        if relatedStoryIDs.contains(id) { return .related }
        return .hidden
    }

    func tierForTable(_ id: String) -> GraphFocusTier {
        if activeTableIDs.contains(id) { return .active }
        if relatedTableIDs.contains(id) { return .related }
        return .hidden
    }

    func visibleStoryIDs() -> Set<String> {
        activeStoryIDs.union(relatedStoryIDs)
    }

    func visibleTableIDs() -> Set<String> {
        activeTableIDs.union(relatedTableIDs)
    }
}

enum StoryStarFormationLayout {
    static func graphPositions(
        hubCenter: CGPoint,
        relatedStoryIDs: [String],
        tableIDs: [String],
        tableSize: (String) -> CGSize,
        gap: CGFloat = 92,
        interItemGap: CGFloat = 36
    ) -> (tablePositions: [String: CGPoint], storyPositions: [String: CGPoint]) {
        let hubSize = CGSize(width: StoryGraphCardLayout.width, height: StoryGraphCardLayout.height)
        let storyItems = relatedStoryIDs.map {
            GraphFocusRingLayout.Item(id: $0, size: hubSize)
        }
        let tableItems = tableIDs.map {
            GraphFocusRingLayout.Item(id: $0, size: tableSize($0))
        }
        let items = storyItems + tableItems
        guard !items.isEmpty else { return ([:], [:]) }

        let layout = GraphFocusRingLayout.graphPositions(
            hubCenter: hubCenter,
            hubSize: hubSize,
            items: items,
            gap: gap,
            interItemGap: interItemGap
        )

        var tablePositions: [String: CGPoint] = [:]
        var storyPositions: [String: CGPoint] = [:]
        let tableIDSet = Set(tableIDs)
        for item in items {
            guard let point = layout[item.id] else { continue }
            if tableIDSet.contains(item.id) {
                tablePositions[item.id] = point
            } else {
                storyPositions[item.id] = point
            }
        }
        return (tablePositions, storyPositions)
    }
}

enum GraphFocusRingLayout {
    struct Item: Sendable, Equatable {
        let id: String
        let size: CGSize
    }

    /// Places related cards around a hub in graph space with spacing that avoids overlap.
    static func graphPositions(
        hubCenter: CGPoint,
        hubSize: CGSize,
        items: [Item],
        gap: CGFloat = 84,
        interItemGap: CGFloat = 32
    ) -> [String: CGPoint] {
        guard !items.isEmpty else { return [:] }

        if items.count == 1 {
            let item = items[0]
            let radius = radialDistance(
                hubSize: hubSize,
                itemSize: item.size,
                angle: -.pi / 2,
                gap: gap
            )
            return [
                item.id: CGPoint(
                    x: hubCenter.x,
                    y: hubCenter.y - radius
                ),
            ]
        }

        var positions: [String: CGPoint] = [:]
        var sizes: [String: CGSize] = [:]
        let count = items.count
        let maxItemExtent = items.map { max($0.size.width, $0.size.height) }.max() ?? 0
        let minRingRadius = count > 1
            ? (maxItemExtent + interItemGap) / (2 * sin(.pi / CGFloat(count)))
            : 0

        for (index, item) in items.enumerated() {
            let angle = -.pi / 2 + (2 * .pi * CGFloat(index) / CGFloat(count))
            let naturalRadius = radialDistance(
                hubSize: hubSize,
                itemSize: item.size,
                angle: angle,
                gap: gap
            )
            let radius = max(naturalRadius, minRingRadius)
            positions[item.id] = CGPoint(
                x: hubCenter.x + radius * cos(angle),
                y: hubCenter.y + radius * sin(angle)
            )
            sizes[item.id] = item.size
        }

        resolveCollisions(
            positions: &positions,
            sizes: sizes,
            hubCenter: hubCenter,
            hubSize: hubSize,
            minimumGap: interItemGap
        )

        return positions
    }

    static func contentBounds(
        hubCenter: CGPoint,
        hubSize: CGSize,
        items: [Item],
        positions: [String: CGPoint]
    ) -> CGRect {
        var bounds = CGRect(
            x: hubCenter.x - hubSize.width / 2,
            y: hubCenter.y - hubSize.height / 2,
            width: hubSize.width,
            height: hubSize.height
        )

        for item in items {
            guard let center = positions[item.id] else { continue }
            let frame = CGRect(
                x: center.x - item.size.width / 2,
                y: center.y - item.size.height / 2,
                width: item.size.width,
                height: item.size.height
            )
            bounds = bounds.union(frame)
        }

        return bounds
    }

    private static func radialDistance(
        hubSize: CGSize,
        itemSize: CGSize,
        angle: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        let cosA = abs(cos(angle))
        let sinA = abs(sin(angle))
        let hubExtent = hubSize.width / 2 * cosA + hubSize.height / 2 * sinA
        let itemExtent = itemSize.width / 2 * cosA + itemSize.height / 2 * sinA
        return hubExtent + gap + itemExtent
    }

    private static func resolveCollisions(
        positions: inout [String: CGPoint],
        sizes: [String: CGSize],
        hubCenter: CGPoint,
        hubSize: CGSize,
        minimumGap: CGFloat,
        maxIterations: Int = 32
    ) {
        let ids = Array(positions.keys)
        for _ in 0..<maxIterations {
            var moved = false

            for id in ids {
                guard var point = positions[id], let size = sizes[id] else { continue }
                if let adjusted = pushAwayFromHub(
                    point: point,
                    size: size,
                    hubCenter: hubCenter,
                    hubSize: hubSize,
                    minimumGap: minimumGap
                ) {
                    positions[id] = adjusted
                    point = adjusted
                    moved = true
                }
            }

            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let lhs = ids[i]
                    let rhs = ids[j]
                    guard var left = positions[lhs], var right = positions[rhs],
                          let leftSize = sizes[lhs], let rightSize = sizes[rhs]
                    else { continue }

                    if separate(
                        lhs: &left,
                        lhsSize: leftSize,
                        rhs: &right,
                        rhsSize: rightSize,
                        minimumGap: minimumGap
                    ) {
                        positions[lhs] = left
                        positions[rhs] = right
                        moved = true
                    }
                }
            }

            if !moved { break }
        }
    }

    private static func pushAwayFromHub(
        point: CGPoint,
        size: CGSize,
        hubCenter: CGPoint,
        hubSize: CGSize,
        minimumGap: CGFloat
    ) -> CGPoint? {
        let dx = point.x - hubCenter.x
        let dy = point.y - hubCenter.y
        let minDistX = (hubSize.width + size.width) / 2 + minimumGap
        let minDistY = (hubSize.height + size.height) / 2 + minimumGap
        let overlapX = minDistX - abs(dx)
        let overlapY = minDistY - abs(dy)
        guard overlapX > 0, overlapY > 0 else { return nil }

        if overlapX < overlapY {
            let push = overlapX * (dx >= 0 ? 1 : -1)
            return CGPoint(x: point.x + push, y: point.y)
        }

        let push = overlapY * (dy >= 0 ? 1 : -1)
        return CGPoint(x: point.x, y: point.y + push)
    }

    private static func separate(
        lhs: inout CGPoint,
        lhsSize: CGSize,
        rhs: inout CGPoint,
        rhsSize: CGSize,
        minimumGap: CGFloat
    ) -> Bool {
        let dx = rhs.x - lhs.x
        let dy = rhs.y - lhs.y
        let minDistX = (lhsSize.width + rhsSize.width) / 2 + minimumGap
        let minDistY = (lhsSize.height + rhsSize.height) / 2 + minimumGap
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
}
