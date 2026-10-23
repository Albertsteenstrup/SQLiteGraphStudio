import CoreGraphics

/// Focus reserves screen space for the table being inspected and its neighbours.
/// Overview metrics and unrelated catalog nodes do not determine this arrangement.
enum GraphFocusSummaryLayout {
    static let rowHeight: CGFloat = 38
    static let edgeLane: CGFloat = 32

    static func edgeLane(rootWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(72, max(edgeLane, (viewportWidth - 48 - rootWidth) / 2 - 190))
    }

    struct Plan {
        let summarySize: CGSize
        let offsets: [String: CGPoint]
    }

    static func plan(rootSize: CGSize, relatedIDs: [String], viewport: CGSize) -> Plan {
        guard !relatedIDs.isEmpty else { return Plan(summarySize: .zero, offsets: [:]) }
        let edgeLane = edgeLane(rootWidth: rootSize.width, viewportWidth: viewport.width)
        let sideWidth = max(32, (viewport.width - 48 - rootSize.width) / 2 - edgeLane)
        let baseWidth = min(190, max(140, sideWidth))
        let availableHeight = max(100, viewport.height - 24)
        var bestColumns = 1
        var bestScale: CGFloat = 0
        for columns in 1...min(12, (relatedIDs.count + 1) / 2) {
            let rows = (relatedIDs.count + columns * 2 - 1) / (columns * 2)
            let width = CGFloat(columns) * baseWidth + CGFloat(columns - 1) * 12
            let height = CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * 8
            let scale = min(1, sideWidth / width, availableHeight / height)
            if scale > bestScale { bestScale = scale; bestColumns = columns }
        }
        let size = CGSize(width: baseWidth * bestScale, height: rowHeight * bestScale)
        var columns = Array(repeating: [String](), count: bestColumns * 2)
        for (index, id) in relatedIDs.enumerated() { columns[index % columns.count].append(id) }
        var offsets: [String: CGPoint] = [:]
        for (index, column) in columns.enumerated() {
            let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            let x = side * (rootSize.width / 2 + edgeLane + size.width / 2
                           + CGFloat(index / 2) * (size.width + 12 * bestScale))
            let height = CGFloat(column.count) * size.height + CGFloat(max(0, column.count - 1)) * 8 * bestScale
            for (row, id) in column.enumerated() {
                offsets[id] = CGPoint(x: x, y: -height / 2 + size.height / 2
                                      + CGFloat(row) * (size.height + 8 * bestScale))
            }
        }
        return Plan(summarySize: size, offsets: offsets)
    }
}
