import CoreGraphics
import Foundation

enum GraphPresentationMode: Sendable, Hashable {
    case compact
    case allCards
}

enum GraphNodeCardStyle: Sendable, Hashable, Equatable {
    case collapsed
    case preview(rowCount: Int)
    case expanded
}

struct GraphViewportTransform: Sendable, Equatable {
    var zoom: CGFloat
    var pan: CGSize

    static let identity = GraphViewportTransform(zoom: 1, pan: .zero)

    func point(for graphPoint: CGPoint, in viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2 + graphPoint.x * zoom + pan.width,
            y: viewportSize.height / 2 + graphPoint.y * zoom + pan.height
        )
    }

    func rect(for graphRect: CGRect, in viewportSize: CGSize) -> CGRect {
        let topLeft = point(for: CGPoint(x: graphRect.minX, y: graphRect.minY), in: viewportSize)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: graphRect.width * zoom,
            height: graphRect.height * zoom
        )
    }

    func graphPoint(for viewportPoint: CGPoint, in viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: (viewportPoint.x - viewportSize.width / 2 - pan.width) / max(zoom, 0.0001),
            y: (viewportPoint.y - viewportSize.height / 2 - pan.height) / max(zoom, 0.0001)
        )
    }

    func magnified(by magnification: CGFloat, at anchor: CGPoint, in viewportSize: CGSize,
                   minZoom: CGFloat = 0.12, maxZoom: CGFloat = 2.4) -> GraphViewportTransform {
        guard viewportSize.width > 0, viewportSize.height > 0, magnification.isFinite,
              zoom.isFinite, zoom > 0, minZoom > 0, maxZoom >= minZoom else { return self }
        let oldZoom = zoom
        let newZoom = max(minZoom, min(oldZoom * (1 + magnification), maxZoom))
        guard newZoom != oldZoom else { return self }
        let centeredAnchor = CGPoint(x: anchor.x - viewportSize.width / 2,
                                    y: anchor.y - viewportSize.height / 2)
        let anchoredPoint = CGPoint(x: (centeredAnchor.x - pan.width) / oldZoom,
                                    y: (centeredAnchor.y - pan.height) / oldZoom)
        return GraphViewportTransform(zoom: newZoom, pan: CGSize(
            width: centeredAnchor.x - anchoredPoint.x * newZoom,
            height: centeredAnchor.y - anchoredPoint.y * newZoom
        ))
    }

    static func fit(
        contentBounds: CGRect,
        in viewportSize: CGSize,
        padding: CGFloat = 120,
        minZoom: CGFloat = 0.45,
        maxZoom: CGFloat = 1.15
    ) -> GraphViewportTransform {
        guard !contentBounds.isNull, !contentBounds.isEmpty else {
            return .identity
        }

        let contentWidth = max(contentBounds.width, 1)
        let contentHeight = max(contentBounds.height, 1)
        let availableWidth = max(viewportSize.width - padding, 1)
        let availableHeight = max(viewportSize.height - padding, 1)
        let fittedZoom = min(availableWidth / contentWidth, availableHeight / contentHeight, maxZoom)
        let zoom = max(minZoom, fittedZoom)
        let contentCenter = CGPoint(x: contentBounds.midX, y: contentBounds.midY)

        return GraphViewportTransform(
            zoom: zoom,
            pan: CGSize(width: -contentCenter.x * zoom, height: -contentCenter.y * zoom)
        )
    }

    /// Brings `contentBounds` into view with as little camera movement as possible.
    ///
    /// Returns `nil` when it is already on screen. Otherwise the camera centres on it at
    /// the reader's zoom, zooming out only as far as needed to fit it — never in, so a
    /// reader who zoomed out to keep a large catalog in view stays zoomed out.
    static func reveal(
        contentBounds: CGRect,
        in viewportSize: CGSize,
        from current: GraphViewportTransform,
        padding: CGFloat = 48,
        minZoom: CGFloat = 0.02
    ) -> GraphViewportTransform? {
        guard !contentBounds.isNull, !contentBounds.isInfinite,
              viewportSize.width > padding * 2, viewportSize.height > padding * 2 else { return nil }
        let visible = CGRect(origin: .zero, size: viewportSize).insetBy(dx: padding, dy: padding)
        if visible.contains(current.rect(for: contentBounds, in: viewportSize)) { return nil }

        let fitZoom = min(visible.width / max(contentBounds.width, 1), visible.height / max(contentBounds.height, 1))
        let zoom = max(min(minZoom, current.zoom), min(current.zoom, fitZoom))
        return GraphViewportTransform(
            zoom: zoom,
            pan: CGSize(width: -contentBounds.midX * zoom, height: -contentBounds.midY * zoom)
        )
    }

    static func focus(
        contentBounds: CGRect,
        in viewportSize: CGSize,
        currentZoom: CGFloat,
        padding: CGFloat = 96,
        preferredZoom: CGFloat = 0.94,
        minZoom: CGFloat = 0.5,
        maxZoom: CGFloat = 1.25
    ) -> GraphViewportTransform {
        guard !contentBounds.isNull, !contentBounds.isEmpty else {
            return .identity
        }

        let availableWidth = max(viewportSize.width - padding, 1)
        let availableHeight = max(viewportSize.height - padding, 1)
        let fitZoom = min(availableWidth / contentBounds.width, availableHeight / contentBounds.height, maxZoom)
        let zoom = max(minZoom, min(max(currentZoom, preferredZoom), fitZoom))
        let contentCenter = CGPoint(x: contentBounds.midX, y: contentBounds.midY)

        return GraphViewportTransform(
            zoom: zoom,
            pan: CGSize(width: -contentCenter.x * zoom, height: -contentCenter.y * zoom)
        )
    }
}

enum GraphReadableCardScale {
    static let focusedMinimum: CGFloat = 0.90

    static func focusedScale(for zoom: CGFloat) -> CGFloat {
        max(zoom, focusedMinimum)
    }

    static func frame(for normalCardFrame: CGRect, zoom: CGFloat, displayScale: CGFloat) -> CGRect {
        guard zoom > 0 else { return normalCardFrame }
        let ratio = displayScale / zoom
        let width = normalCardFrame.width * ratio
        let height = normalCardFrame.height * ratio
        return CGRect(x: normalCardFrame.midX - width / 2,
                      y: normalCardFrame.midY - height / 2,
                      width: width, height: height)
    }
}

enum GraphCardRole: Sendable, Hashable {
    case collapsedNode
    case previewNode
    case expandedNode
    case floatingDetails
}

enum GraphCardLayout {
    static let collapsedHeight: CGFloat = 46
    static let previewHeaderHeight: CGFloat = 46
    static let previewRowHeight: CGFloat = 24
    static let previewVerticalPadding: CGFloat = 12
    static let previewBodyTopPadding: CGFloat = 10
    static let previewWidth: CGFloat = 440
    static let expandedHeaderHeight: CGFloat = 46
    static let expandedRowHeight: CGFloat = 24
    static let expandedVerticalPadding: CGFloat = 12
    static let expandedBodyTopPadding: CGFloat = 10
    static let expandedWidth: CGFloat = 440
    static let maxExpandedVisibleRows = 7
    static let floatingHeaderHeight: CGFloat = 52
    static let floatingSummaryHeight: CGFloat = 28
    static let floatingSectionSpacing: CGFloat = 12
    static let floatingSectionHeaderHeight: CGFloat = 20
    static let floatingRowHeight: CGFloat = 26
    static let floatingVerticalPadding: CGFloat = 14
    static let floatingBodyTopPadding: CGFloat = 10
    static let floatingEdgeLineHeight: CGFloat = 18
    static let floatingWidth: CGFloat = 360
    static let horizontalInset: CGFloat = 14

    static func nodeSize(
        title: String,
        descriptor: EditableTableDescriptor?,
        style: GraphNodeCardStyle,
        hovered: Bool = false
    ) -> CGSize {
        switch style {
        case .collapsed:
            return CGSize(
                width: collapsedWidth(title: title, hovered: hovered),
                height: collapsedHeight
            )
        case .preview(let rowCount):
            return CGSize(
                width: previewWidth,
                height: previewHeaderHeight + previewBodyTopPadding + previewVerticalPadding + CGFloat(max(rowCount, 1)) * previewRowHeight
            )
        case .expanded:
            let columnCount = descriptor?.columns.count ?? 0
            return CGSize(
                width: expandedWidth,
                height: expandedHeaderHeight + expandedBodyTopPadding + expandedVerticalPadding + CGFloat(min(columnCount, maxExpandedVisibleRows)) * expandedRowHeight
            )
        }
    }

    static func collapsedWidth(title: String, hovered: Bool) -> CGFloat {
        // Hover must not enlarge a card into its neighbors.
        let characterWidth: CGFloat = 9.8
        let chromeWidth: CGFloat = 182
        let minWidth: CGFloat = 226
        let maxWidth: CGFloat = 560
        return min(max(minWidth, CGFloat(title.count) * characterWidth + chromeWidth), maxWidth)
    }

    static func floatingDetailsSize(
        descriptor: EditableTableDescriptor?,
        outgoingCount: Int,
        incomingCount: Int
    ) -> CGSize {
        let columnCount = descriptor?.columns.count ?? 0
        var height = floatingHeaderHeight + floatingSummaryHeight
        height += floatingBodyTopPadding + floatingVerticalPadding + CGFloat(columnCount) * floatingRowHeight

        if outgoingCount > 0 {
            height += floatingSectionSpacing + floatingSectionHeaderHeight + CGFloat(outgoingCount) * floatingEdgeLineHeight
        }
        if incomingCount > 0 {
            height += floatingSectionSpacing + floatingSectionHeaderHeight + CGFloat(incomingCount) * floatingEdgeLineHeight
        }

        return CGSize(width: floatingWidth, height: height)
    }

    static func rowFrame(columnIndex: Int, in frame: CGRect, role: GraphCardRole, scale: CGFloat = 1) -> CGRect? {
        switch role {
        case .collapsedNode:
            return nil
        case .previewNode:
            let y = frame.minY + (previewHeaderHeight + previewBodyTopPadding + CGFloat(columnIndex) * previewRowHeight) * scale
            return CGRect(
                x: frame.minX + horizontalInset * scale,
                y: y,
                width: frame.width - horizontalInset * 2 * scale,
                height: previewRowHeight * scale
            )
        case .expandedNode:
            let y = frame.minY + (expandedHeaderHeight + expandedBodyTopPadding + CGFloat(columnIndex) * expandedRowHeight) * scale
            return CGRect(
                x: frame.minX + horizontalInset * scale,
                y: y,
                width: frame.width - horizontalInset * 2 * scale,
                height: expandedRowHeight * scale
            )
        case .floatingDetails:
            let y = frame.minY + floatingHeaderHeight + floatingSummaryHeight + floatingBodyTopPadding + CGFloat(columnIndex) * floatingRowHeight
            return CGRect(
                x: frame.minX + horizontalInset,
                y: y,
                width: frame.width - horizontalInset * 2,
                height: floatingRowHeight
            )
        }
    }
}

/// Space between cards leaves room for the line leaving a key row and its
/// cardinality, rather than merely preventing card bodies from intersecting.
enum GraphCardClearance {
    static let minimumGap: CGFloat = 80
}

/// Packs a chosen set of cards in caller order using their rendered sizes.
/// Column and row extents keep long names and expanded cards from overlapping.
enum GraphCompactPlacement {
    struct Item {
        let id: String
        let size: CGSize
    }

    static func positions(
        for items: [Item],
        columns requestedColumns: Int,
        around center: CGPoint,
        columnGap: CGFloat = 160,
        rowGap: CGFloat = 140
    ) -> [String: CGPoint] {
        var seen = Set<String>()
        let items = items.filter { seen.insert($0.id).inserted }
        guard !items.isEmpty else { return [:] }
        let columns = min(items.count, max(1, requestedColumns))
        let rows = (items.count + columns - 1) / columns
        var widths = Array(repeating: CGFloat.zero, count: columns)
        var heights = Array(repeating: CGFloat.zero, count: rows)
        for (index, item) in items.enumerated() {
            widths[index % columns] = max(widths[index % columns], item.size.width)
            heights[index / columns] = max(heights[index / columns], item.size.height)
        }

        let totalWidth = widths.reduce(0, +) + CGFloat(columns - 1) * columnGap
        let totalHeight = heights.reduce(0, +) + CGFloat(rows - 1) * rowGap
        var xCenters: [CGFloat] = []
        var x = center.x - totalWidth / 2
        for width in widths {
            xCenters.append(x + width / 2)
            x += width + columnGap
        }
        var yCenters: [CGFloat] = []
        var y = center.y - totalHeight / 2
        for height in heights {
            yCenters.append(y + height / 2)
            y += height + rowGap
        }
        return Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (item.id, CGPoint(x: xCenters[index % columns], y: yCenters[index / columns]))
        })
    }
}

struct GraphEdgeAnchors: Sendable, Equatable {
    let source: CGPoint
    let target: CGPoint
}

struct GraphCardGeometry: Sendable, Equatable {
    let tableID: String
    let frame: CGRect
    let role: GraphCardRole
    let rowFrames: [String: CGRect]

    init(
        tableID: String,
        frame: CGRect,
        role: GraphCardRole,
        descriptor: @autoclosure () -> EditableTableDescriptor?,
        displayedColumns: [String]? = nil,
        scale: CGFloat = 1
    ) {
        self.tableID = tableID
        self.frame = frame
        self.role = role

        var rowFrames: [String: CGRect] = [:]
        if role != .collapsedNode, let descriptor = descriptor() {
            let visibleColumnNames = displayedColumns ?? Self.defaultDisplayedColumns(for: descriptor, role: role)
            for (index, columnName) in visibleColumnNames.enumerated() {
                if let rowFrame = GraphCardLayout.rowFrame(columnIndex: index, in: frame, role: role, scale: scale) {
                    rowFrames[columnName] = rowFrame
                }
            }
        }
        self.rowFrames = rowFrames
    }

    private static func defaultDisplayedColumns(for descriptor: EditableTableDescriptor, role: GraphCardRole) -> [String] {
        switch role {
        case .expandedNode:
            return descriptor.columns.prefix(GraphCardLayout.maxExpandedVisibleRows).map(\.name)
        case .collapsedNode:
            return []
        case .previewNode, .floatingDetails:
            return descriptor.columns.map(\.name)
        }
    }

    var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Returns the header region (above the first column row). For collapsed cards this is the entire frame.
    var headerFrame: CGRect {
        if let firstRowMinY = rowFrames.values.map(\.minY).min() {
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: firstRowMinY - frame.minY)
        }
        return frame
    }

    func columnName(at point: CGPoint) -> String? {
        rowFrames
            .filter { $0.value.contains(point) }
            .min { lhs, rhs in
                if lhs.value.minY == rhs.value.minY {
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
                return lhs.value.minY < rhs.value.minY
            }?
            .key
    }

    func anchor(for columnName: String, toward point: CGPoint) -> CGPoint? {
        guard let rowFrame = rowFrames[columnName] else { return nil }
        if point.x >= frame.midX {
            return CGPoint(x: frame.maxX, y: rowFrame.midY)
        }
        return CGPoint(x: frame.minX, y: rowFrame.midY)
    }

    func nearestSideMidpoint(toward point: CGPoint) -> CGPoint {
        let candidates = [
            CGPoint(x: frame.minX, y: frame.midY),
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY),
            CGPoint(x: frame.midX, y: frame.maxY),
        ]

        return candidates.min(by: { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        }) ?? center
    }
}

struct GraphAnchorMap: Sendable, Equatable {
    let nodeCards: [String: GraphCardGeometry]
    let floatingCard: GraphCardGeometry?
    let contentBounds: CGRect

    init(
        nodeCards: [String: GraphCardGeometry],
        floatingCard: GraphCardGeometry? = nil
    ) {
        self.nodeCards = nodeCards
        self.floatingCard = floatingCard
        self.contentBounds = nodeCards.values.reduce(into: CGRect.null) { partial, geometry in
            partial = partial.union(geometry.frame)
        }
    }

    func card(for tableID: String) -> GraphCardGeometry? {
        if floatingCard?.tableID == tableID {
            return floatingCard
        }
        return nodeCards[tableID]
    }

    func edgeAnchors(for edge: GraphEdge) -> GraphEdgeAnchors? {
        guard let sourceCard = card(for: edge.sourceID), let targetCard = card(for: edge.targetID) else {
            return nil
        }

        let sourceFallback = sourceCard.nearestSideMidpoint(toward: targetCard.center)
        let source = sourceCard.anchor(for: edge.sourceColumn, toward: targetCard.center) ?? sourceFallback
        let target = targetCard.anchor(for: edge.targetColumn, toward: source) ?? targetCard.nearestSideMidpoint(toward: source)

        return GraphEdgeAnchors(source: source, target: target)
    }
}

/// Card-aware tangents keep vertical and return links outside their endpoint
/// cards. Parallel foreign keys use stable lanes instead of identical curves.
enum GraphEdgeRouting {
    struct Curve: Sendable, Equatable {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            bezierPoint(start: start, control1: control1, control2: control2, end: end, t: t)
        }
    }

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    static func laneOffsets(for edges: [GraphEdge], spacing: CGFloat = 24) -> [String: CGFloat] {
        let groups = Dictionary(grouping: edges) { edge in
            Pair(first: min(edge.sourceID, edge.targetID), second: max(edge.sourceID, edge.targetID))
        }
        var offsets: [String: CGFloat] = [:]
        for group in groups.values {
            let ordered = group.sorted {
                ($0.sourceID, $0.sourceColumn, $0.targetID, $0.targetColumn, $0.id)
                    < ($1.sourceID, $1.sourceColumn, $1.targetID, $1.targetColumn, $1.id)
            }
            for (index, edge) in ordered.enumerated() {
                let orientation: CGFloat = edge.sourceID <= edge.targetID ? 1 : -1
                offsets[edge.id] = (CGFloat(index) - CGFloat(ordered.count - 1) / 2) * spacing * orientation
            }
        }
        return offsets
    }

    static func curve(anchors: GraphEdgeAnchors, sourceFrame: CGRect?, targetFrame: CGRect?,
                      laneOffset: CGFloat = 0, isSelfLink: Bool = false) -> Curve {
        let start = anchors.source
        let end = anchors.target
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        let offset = max(32, min(180, distance * 0.34))
        let sourceNormal = outwardNormal(at: start, frame: sourceFrame,
                                         fallback: CGVector(dx: dx >= 0 ? 1 : -1, dy: 0))
        let targetNormal = outwardNormal(at: end, frame: targetFrame,
                                         fallback: CGVector(dx: dx >= 0 ? -1 : 1, dy: 0))
        let perpendicular = distance > 0 ? CGVector(dx: -dy / distance, dy: dx / distance) : CGVector(dx: 0, dy: 1)
        if isSelfLink {
            let reach: CGFloat = max(64, offset) + abs(laneOffset)
            let tangent = CGVector(dx: -sourceNormal.dy, dy: sourceNormal.dx)
            return Curve(start: start,
                         control1: CGPoint(x: start.x + sourceNormal.dx * reach - tangent.dx * 36,
                                           y: start.y + sourceNormal.dy * reach - tangent.dy * 36),
                         control2: CGPoint(x: end.x + targetNormal.dx * reach + tangent.dx * 36,
                                           y: end.y + targetNormal.dy * reach + tangent.dy * 36), end: end)
        }
        let lane = CGVector(dx: perpendicular.dx * laneOffset, dy: perpendicular.dy * laneOffset)
        return Curve(start: start,
                     control1: laneAdjustedControl(at: start, normal: sourceNormal, reach: offset, lane: lane),
                     control2: laneAdjustedControl(at: end, normal: targetNormal, reach: offset, lane: lane), end: end)
    }

    private static func laneAdjustedControl(at point: CGPoint, normal: CGVector, reach: CGFloat,
                                            lane: CGVector) -> CGPoint {
        let normalLane = lane.dx * normal.dx + lane.dy * normal.dy
        let tangentLane = CGVector(dx: lane.dx - normal.dx * normalLane,
                                   dy: lane.dy - normal.dy * normalLane)
        // The screen-space lane direction may oppose the card's outward side.
        // Compress that component smoothly to less than the normal reach;
        // clamping would make several dense lanes collapse onto one curve.
        let outwardReach = reach * (1 + 0.75 * normalLane / (reach + abs(normalLane)))
        return CGPoint(x: point.x + normal.dx * outwardReach + tangentLane.dx,
                       y: point.y + normal.dy * outwardReach + tangentLane.dy)
    }

    private static func outwardNormal(at point: CGPoint, frame: CGRect?, fallback: CGVector) -> CGVector {
        guard let frame, !frame.isNull, !frame.isEmpty else { return fallback }
        let sides: [(CGFloat, CGVector)] = [
            (abs(point.x - frame.minX), CGVector(dx: -1, dy: 0)),
            (abs(point.x - frame.maxX), CGVector(dx: 1, dy: 0)),
            (abs(point.y - frame.minY), CGVector(dx: 0, dy: -1)),
            (abs(point.y - frame.maxY), CGVector(dx: 0, dy: 1)),
        ]
        return sides.min { $0.0 < $1.0 }!.1
    }
}

/// Endpoint labels stay beside their line, outside cards and other labels.
/// A crowded endpoint omits its duplicate mark rather than stacking unreadable
/// stars and ones; hovering one relation still exposes its own cardinality.
enum GraphCardinalityLabelPlacement {
    static let labelSize = CGSize(width: 14, height: 16)

    static func position(on curve: GraphEdgeRouting.Curve, atSource: Bool,
                         cardFrames: [CGRect], occupied: inout [CGRect]) -> CGPoint? {
        let samples: [CGFloat] = atSource ? [0.16, 0.22, 0.28, 0.34, 0.40] : [0.84, 0.78, 0.72, 0.66, 0.60]
        for t in samples {
            let point = curve.point(at: t)
            let rect = CGRect(x: point.x - labelSize.width / 2, y: point.y - labelSize.height / 2,
                              width: labelSize.width, height: labelSize.height)
            let clearance = rect.insetBy(dx: -3, dy: -3)
            guard !cardFrames.contains(where: { $0.intersects(clearance) }),
                  !occupied.contains(where: { $0.intersects(clearance) }) else { continue }
            occupied.append(rect)
            return point
        }
        return nil
    }
}

// MARK: - Bézier helpers

/// Returns the point on a cubic Bézier curve at parameter `t` ∈ [0, 1].
///
/// Formula: B(t) = (1-t)³·P0 + 3(1-t)²t·P1 + 3(1-t)t²·P2 + t³·P3
func bezierPoint(
    start: CGPoint,
    control1: CGPoint,
    control2: CGPoint,
    end: CGPoint,
    t: CGFloat
) -> CGPoint {
    let u = 1 - t
    let uu = u * u
    let uuu = uu * u
    let tt = t * t
    let ttt = tt * t

    return CGPoint(
        x: uuu * start.x + 3 * uu * t * control1.x + 3 * u * tt * control2.x + ttt * end.x,
        y: uuu * start.y + 3 * uu * t * control1.y + 3 * u * tt * control2.y + ttt * end.y
    )
}

/// Returns the tangent vector (not normalized) of a cubic Bézier curve at parameter `t` ∈ [0, 1].
///
/// Formula: B'(t) = 3(1-t)²·(P1-P0) + 6(1-t)t·(P2-P1) + 3t²·(P3-P2)
func bezierTangent(
    start: CGPoint,
    control1: CGPoint,
    control2: CGPoint,
    end: CGPoint,
    t: CGFloat
) -> CGVector {
    let u = 1 - t
    let uu = u * u
    let tt = t * t

    let dx = 3 * uu * (control1.x - start.x)
           + 6 * u * t * (control2.x - control1.x)
           + 3 * tt * (end.x - control2.x)
    let dy = 3 * uu * (control1.y - start.y)
           + 6 * u * t * (control2.y - control1.y)
           + 3 * tt * (end.y - control2.y)

    return CGVector(dx: dx, dy: dy)
}

/// Returns the display string for the given `EdgeCardinality`.
///
/// - `.oneToOne`  → `"1:1"`
/// - `.oneToMany` → `"1:N"`
/// - `.manyToOne` → `"N:1"`
/// - `.manyToMany` → `"N:M"`
func cardinalityDisplayString(for cardinality: EdgeCardinality) -> String {
    switch cardinality {
    case .oneToOne:   return "1:1"
    case .oneToMany:  return "1:N"
    case .manyToOne:  return "N:1"
    case .manyToMany: return "N:M"
    }
}

enum ClusterTitleCacheToken {
    static func make(
        layoutRevision: Int,
        sidecarRevision: Int,
        hasFocusPlan: Bool,
        showClusterHalos: Bool
    ) -> Int {
        var token = layoutRevision &* 31 &+ sidecarRevision
        token = token &* 31 &+ (hasFocusPlan ? 1 : 0)
        token = token &* 31 &+ (showClusterHalos ? 1 : 0)
        return token
    }
}
