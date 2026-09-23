import Foundation

/// What the relation layer paints for one frame of the scene.
///
/// Both the static lines and the travelling pulses are built from one plan, so a signal
/// can never appear on a relation whose line is hidden.
struct GraphEdgeLayerPlan {
    /// Relations a large catalog paints while zoomed out. A cap is needed because nothing
    /// is off screen at that zoom, so viewport culling cannot do the job; below this many
    /// relations every one is painted.
    static let overviewRelationLimit = 1_200

    /// Zoomed-out relations sit further back than the detail view's, so a dense catalog
    /// reads as texture rather than as a grey mat — while still giving the pulses a line
    /// to travel along.
    static let overviewInkScale = 0.62

    /// How the relation layer behaves for the current zoom and preferences.
    enum Mode: Equatable {
        /// Close enough to read individual tables: paint every visible relation.
        case detail
        /// Zoomed out: paint a bounded, faint sample of real relations.
        case overviewSample
        /// Zoomed out with relations switched off: paint only what the pointer touches.
        case overviewHoverOnly
    }

    /// Returns `nil` when the layer paints nothing at all — zoomed out, relations off, and
    /// no table under the pointer, which is the state the overview ships in for catalogs
    /// too large to draw edge by edge.
    ///
    /// A schema review always paints in full, at any zoom. Its whole subject is which
    /// relations changed, and a bounded sample could drop one of them.
    static func mode(
        isOverview: Bool,
        isSchemaReview: Bool,
        showsOverviewRelations: Bool,
        hasHover: Bool
    ) -> Mode? {
        guard isOverview, !isSchemaReview else { return .detail }
        if showsOverviewRelations { return .overviewSample }
        return hasHover ? .overviewHoverOnly : nil
    }

    let highlight: GraphRelationHighlight
    let focusPlan: GraphFocusPlan?
    /// Paint only the relations under the pointer.
    let onlyHighlighted: Bool
    /// Cap on relations painted, or `nil` for every visible one.
    let sampleLimit: Int?
    /// Multiplier on the resting line's opacity and width.
    let inkScale: Double
}
