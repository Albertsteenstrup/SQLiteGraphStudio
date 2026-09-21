import CoreGraphics
import Foundation

public enum GraphNodeSizeMetric: String, CaseIterable, Identifiable, Sendable {
    case uniform, fields, rows, relations

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// A full-catalog scale, rebuilt on data/metric changes rather than camera updates.
/// Filtering never participates in normalization. Unknown rows are neutral, not zero.
struct GraphNodeSizeProfile: Equatable, Sendable {
    let metric: GraphNodeSizeMetric
    let areas: [String: CGFloat]
    let unknownIDs: Set<String>

    static let uniform = GraphNodeSizeProfile(metric: .uniform, areas: [:], unknownIDs: [])

    init(metric: GraphNodeSizeMetric, tables: [TableSummary], rowCounts: [String: Int], relationCounts: [String: Int]) {
        self.metric = metric
        guard metric != .uniform else { areas = [:]; unknownIDs = []; return }
        var counts: [String: Int] = [:]
        var unknown: Set<String> = []
        for table in tables {
            let value: Int?
            switch metric {
            case .uniform: value = nil
            case .fields: value = table.columnCount
            case .rows: value = rowCounts[table.id] ?? table.rowCount
            case .relations: value = relationCounts[table.id, default: 0]
            }
            if let value, value >= 0 { counts[table.id] = value }
            else { unknown.insert(table.id) }
        }
        let maximum = max(1, counts.values.max() ?? 0)
        let denominator = log1p(Double(maximum))
        // Log compression stops a million-row table from overwhelming smaller ones.
        areas = counts.mapValues { 0.12 + 0.88 * CGFloat(log1p(Double($0)) / denominator) }
        unknownIDs = unknown
    }

    private init(metric: GraphNodeSizeMetric, areas: [String: CGFloat], unknownIDs: Set<String>) {
        self.metric = metric
        self.areas = areas
        self.unknownIDs = unknownIDs
    }

    static func emphasis(at zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 0 }
        let t = min(1, max(0, zoom / GraphExploration.detailZoom))
        return 1 - t * t * (3 - 2 * t)
    }

    func markerFrame(for id: String, frame: CGRect, zoom: CGFloat) -> CGRect {
        guard metric != .uniform else { return GraphExploration.markerFrame(for: frame) }
        let emphasis = Self.emphasis(at: zoom)
        let area = areas[id] ?? 0.45
        let factor = sqrt(area)
        // All metrics converge toward one common marker footprint, independent of
        // title length and expanded column count. It fits inside the original card
        // allocation, so zooming never moves nodes or introduces new overlaps.
        let safeZoom = zoom.isFinite ? max(0, zoom) : 0
        let baseWidth = GraphCardLayout.collapsedWidth(title: "", hovered: false) * safeZoom
        let baseHeight = GraphCardLayout.collapsedHeight * safeZoom
        let width = frame.width + (min(frame.width, baseWidth) * factor - frame.width) * emphasis
        let height = frame.height + (min(frame.height, baseHeight) * factor - frame.height) * emphasis
        return GraphExploration.markerFrame(for: CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                                                        width: width, height: height))
    }
}
