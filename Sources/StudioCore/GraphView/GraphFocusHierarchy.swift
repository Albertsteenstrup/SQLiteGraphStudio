import CoreGraphics

enum GraphFocusTier: Sendable, Equatable {
    case hidden
    case related
    case active
}

struct GraphFocusPlan: Sendable, Equatable {
    let activeTableIDs: Set<String>
    let relatedTableIDs: Set<String>

    var isActive: Bool {
        !activeTableIDs.isEmpty
    }

    func tierForTable(_ id: String) -> GraphFocusTier {
        if activeTableIDs.contains(id) { return .active }
        if relatedTableIDs.contains(id) { return .related }
        return .hidden
    }

    func visibleTableIDs() -> Set<String> {
        activeTableIDs.union(relatedTableIDs)
    }
}

enum GraphFocusEdgeEmphasis {
    static func highlightedTableID(focusedHubID: String?, hoveredTableID: String?,
                                   selectedTableID: String?, fallbackID: String?) -> String? {
        guard let focusedHubID else { return fallbackID }
        if let hoveredTableID, hoveredTableID != focusedHubID { return hoveredTableID }
        if let selectedTableID, selectedTableID != focusedHubID { return selectedTableID }
        return nil
    }

    static func showsEdge(sourceID: String, targetID: String, focusedHubID: String?) -> Bool {
        guard let focusedHubID else { return true }
        return sourceID == focusedHubID || targetID == focusedHubID
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
        interItemGap: CGFloat = 32,
        viewportSize: CGSize = .zero
    ) -> [String: CGPoint] {
        guard !items.isEmpty else { return [:] }

        if items.count > 16, viewportSize.width > 0, viewportSize.height > 0 {
            return overviewColumnPositions(hubCenter: hubCenter, hubSize: hubSize,
                                           items: items, viewportSize: viewportSize,
                                           interItemGap: interItemGap)
        }

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

        // A dense ring forces the camera so far out that even the expanded hub
        // becomes unreadable. Keep a bounded page in two short columns instead.
        if items.count > 6 {
            return columnPositions(hubCenter: hubCenter, hubSize: hubSize, items: items,
                                   gap: max(gap, 220), interItemGap: interItemGap)
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

    /// Keep every direct neighbour in one focus scene. Choose the number of
    /// columns that gives their cards the largest fitted scale, while reserving
    /// screen space for the enlarged hub and a visible edge lane beside it.
    private static func overviewColumnPositions(hubCenter: CGPoint, hubSize: CGSize,
                                                items: [Item], viewportSize: CGSize,
                                                interItemGap: CGFloat) -> [String: CGPoint] {
        let columnGap: CGFloat = 24
        let rowGap = min(interItemGap, 24)
        let edgeLane: CGFloat = 24
        let rootDisplayWidth = hubSize.width * GraphReadableCardScale.focusedMinimum
        let availableWidth = max(viewportSize.width - 48, 300)
        let availableHeight = max(viewportSize.height - min(100, viewportSize.height * 0.3) - 94, 120)
        let sideWidth = max((availableWidth - rootDisplayWidth) / 2 - edgeLane, 40)
        let maximumColumnsPerSide = min(12, (items.count + 1) / 2)

        var bestColumns: [[Item]] = []
        var bestZoom: CGFloat = 0
        for columnsPerSide in 1...maximumColumnsPerSide {
            var columns = Array(repeating: [Item](), count: columnsPerSide * 2)
            for (index, item) in items.enumerated() {
                columns[index % columns.count].append(item)
            }
            let widths: [CGFloat] = columns.map { column in
                column.map { $0.size.width }.max() ?? 0
            }
            var sideWidths = [CGFloat.zero, CGFloat.zero]
            for side in 0..<2 {
                for column in 0..<columnsPerSide {
                    sideWidths[side] += widths[column * 2 + side]
                    if column > 0 { sideWidths[side] += columnGap }
                }
            }
            let tallest = columns.map { column in
                column.reduce(CGFloat.zero) { $0 + $1.size.height }
                    + CGFloat(max(column.count - 1, 0)) * rowGap
            }.max() ?? 1
            let fittedZoom = min(sideWidth / max(sideWidths.max() ?? 1, 1),
                                 availableHeight / max(tallest, 1), 0.9)
            if fittedZoom > bestZoom {
                bestZoom = fittedZoom
                bestColumns = columns
            }
        }

        let zoom = max(bestZoom, 0.01)
        let firstColumnEdge = (rootDisplayWidth / 2 + edgeLane) / zoom
        var positions: [String: CGPoint] = [:]
        for side in 0..<2 {
            let direction: CGFloat = side == 0 ? -1 : 1
            var offset = firstColumnEdge
            for columnIndex in 0..<(bestColumns.count / 2) {
                let column = bestColumns[columnIndex * 2 + side]
                let width = column.map(\.size.width).max() ?? 0
                let height = column.reduce(CGFloat.zero) { $0 + $1.size.height }
                    + CGFloat(max(column.count - 1, 0)) * rowGap
                let x = hubCenter.x + direction * (offset + width / 2)
                var y = hubCenter.y - height / 2
                for item in column {
                    positions[item.id] = CGPoint(x: x, y: y + item.size.height / 2)
                    y += item.size.height + rowGap
                }
                offset += width + columnGap
            }
        }
        return positions
    }

    private static func columnPositions(hubCenter: CGPoint, hubSize: CGSize,
                                        items: [Item], gap: CGFloat, interItemGap: CGFloat) -> [String: CGPoint] {
        let left = items.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        let right = items.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element }
        var positions: [String: CGPoint] = [:]

        for (column, direction) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            guard !column.isEmpty else { continue }
            let widest = column.map(\.size.width).max() ?? 0
            let height = column.reduce(CGFloat.zero) { $0 + $1.size.height }
                + CGFloat(column.count - 1) * interItemGap
            let x = hubCenter.x + direction * (hubSize.width / 2 + gap + widest / 2)
            var y = hubCenter.y - height / 2
            for item in column {
                positions[item.id] = CGPoint(x: x, y: y + item.size.height / 2)
                y += item.size.height + interItemGap
            }
        }
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
