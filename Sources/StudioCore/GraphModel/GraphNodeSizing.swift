import CoreGraphics
import Foundation

public enum GraphNodeSizeMetric: String, CaseIterable, Identifiable, Sendable {
    case uniform, fields, rows, relations

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var explanation: String {
        switch self {
        case .uniform: return "All nodes use the default size."
        case .fields: return "Larger nodes have more fields."
        case .rows: return "Larger nodes have more available rows; counts may be estimates."
        case .relations: return "Larger nodes have more declared database relationships."
        }
    }
}

/// Bounded, full-catalog evidence for choosing a useful overview scale.
/// Available row counts can include database estimates; missing is not zero.
public struct GraphNodeSizeData: Sendable, Equatable {
    public let objectCount: Int
    public let minimumFields: Int?
    public let maximumFields: Int?
    public let availableRowCounts: Int
    public let minimumRows: Int?
    public let maximumRows: Int?
    public let connectedObjects: Int
    public let maximumRelations: Int

    public init(tables: [TableSummary], rowCounts: [String: Int], relationCounts: [String: Int]) {
        objectCount = tables.count
        let fields = tables.map(\.columnCount)
        minimumFields = fields.min()
        maximumFields = fields.max()
        let rows = tables.compactMap { table -> Int? in
            guard let count = rowCounts[table.id] ?? table.rowCount, count >= 0 else { return nil }
            return count
        }
        availableRowCounts = rows.count
        minimumRows = rows.min()
        maximumRows = rows.max()
        let relations = tables.map { relationCounts[$0.id, default: 0] }
        connectedObjects = relations.filter { $0 > 0 }.count
        maximumRelations = relations.max() ?? 0
    }
}

/// A full-catalog scale, rebuilt on data/metric changes rather than camera updates.
/// Filtering never participates in normalization. Unknown rows are neutral, not zero.
struct GraphNodeSizeProfile: Equatable, Sendable {
    let metric: GraphNodeSizeMetric
    let areas: [String: CGFloat]
    let unknownIDs: Set<String>
    private let minimumArea: CGFloat
    private let maximumArea: CGFloat

    static let uniform = GraphNodeSizeProfile(metric: .uniform, areas: [:], unknownIDs: [])

    init(metric: GraphNodeSizeMetric, tables: [TableSummary], rowCounts: [String: Int], relationCounts: [String: Int]) {
        self.metric = metric
        guard metric != .uniform else {
            areas = [:]; unknownIDs = []; minimumArea = 0; maximumArea = 0
            return
        }
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
        let areas = counts.mapValues { 0.12 + 0.88 * CGFloat(log1p(Double($0)) / denominator) }
        self.areas = areas
        minimumArea = areas.values.min() ?? 0
        maximumArea = areas.values.max() ?? 0
        unknownIDs = unknown
    }

    private init(metric: GraphNodeSizeMetric, areas: [String: CGFloat], unknownIDs: Set<String>) {
        self.metric = metric
        self.areas = areas
        self.unknownIDs = unknownIDs
        minimumArea = areas.values.min() ?? 0
        maximumArea = areas.values.max() ?? 0
    }

    /// Use the full observed range, so even modest differences in field/link counts
    /// are visible. Equal counts and missing row counts keep a neutral footprint.
    func dimensionScale(for id: String) -> CGFloat {
        guard metric != .uniform, let area = areas[id], maximumArea > minimumArea else { return 1 }
        return 0.55 + 2.45 * (area - minimumArea) / (maximumArea - minimumArea)
    }

    /// Reserve the largest footprint at every zoom, including the
    /// three-pixel marker minimum, hover emphasis, and a readable focus root.
    func layoutSize(for id: String, cardSize: CGSize, minimumZoom: CGFloat, isFocusRoot: Bool = false) -> CGSize {
        guard metric != .uniform else { return cardSize }
        let factor = dimensionScale(for: id)
        let zoom = max(0.005, minimumZoom.isFinite ? minimumZoom : 1)
        let minimum = 3 / zoom
        let readableScale = isFocusRoot ? GraphReadableCardScale.focusedScale(for: zoom) / zoom : 1
        let clearanceScale = GraphHoverPresentation.clearanceScale
        return CGSize(
            width: max(cardSize.width * readableScale, cardSize.width * factor, minimum) * clearanceScale,
            height: max(cardSize.height * readableScale, cardSize.height * factor, minimum) * clearanceScale
        )
    }

    /// Keep the metric's proportions as markers become labeled cards. Scaling
    /// both dimensions together also preserves the card's text and row geometry.
    func frame(for id: String, frame: CGRect) -> CGRect {
        GraphHoverPresentation.enlarged(frame, scale: dimensionScale(for: id))
    }

    func markerFrame(for id: String, frame: CGRect) -> CGRect {
        GraphExploration.markerFrame(for: self.frame(for: id, frame: frame))
    }
}
