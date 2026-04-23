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
    static let previewWidth: CGFloat = 308
    static let expandedHeaderHeight: CGFloat = 46
    static let expandedRowHeight: CGFloat = 24
    static let expandedVerticalPadding: CGFloat = 12
    static let expandedBodyTopPadding: CGFloat = 10
    static let expandedWidth: CGFloat = 308
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
        let characterWidth: CGFloat = hovered ? 10.8 : 9.8
        let chromeWidth: CGFloat = hovered ? 144 : 118
        let minWidth: CGFloat = hovered ? 220 : 164
        let maxWidth: CGFloat = hovered ? 420 : 320
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
        descriptor: EditableTableDescriptor?,
        displayedColumns: [String]? = nil,
        scale: CGFloat = 1
    ) {
        self.tableID = tableID
        self.frame = frame
        self.role = role

        var rowFrames: [String: CGRect] = [:]
        if let descriptor {
            let visibleColumnNames = displayedColumns ?? descriptor.columns.map(\.name)
            for (index, columnName) in visibleColumnNames.enumerated() {
                if let rowFrame = GraphCardLayout.rowFrame(columnIndex: index, in: frame, role: role, scale: scale) {
                    rowFrames[columnName] = rowFrame
                }
            }
        }
        self.rowFrames = rowFrames
    }

    var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    func anchor(for columnName: String, toward point: CGPoint) -> CGPoint? {
        guard let rowFrame = rowFrames[columnName] else { return nil }
        if point.x >= frame.midX {
            return CGPoint(x: rowFrame.maxX, y: rowFrame.midY)
        }
        return CGPoint(x: rowFrame.minX, y: rowFrame.midY)
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
