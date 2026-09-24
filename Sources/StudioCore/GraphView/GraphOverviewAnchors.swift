import CoreGraphics

/// Important overview tables use the same full card as other tables, but shrink
/// more slowly while the surrounding catalog turns into compact markers.
enum GraphOverviewAnchors {
    struct Anchor: Hashable {
        let id: String
    }

    static let cardTransitionZoom: CGFloat = 0.78
    private static let readableZoom: CGFloat = 0.20
    private static let readableScale: CGFloat = 0.70

    static func displayScale(for zoom: CGFloat) -> CGFloat {
        guard zoom > 0 else { return 0 }
        guard zoom < cardTransitionZoom else { return zoom }
        if zoom <= readableZoom { return readableScale * (zoom / readableZoom).squareRoot() }
        let progress = (zoom - readableZoom) / (cardTransitionZoom - readableZoom)
        return readableScale + (cardTransitionZoom - readableScale) * progress
    }

    static func frame(for normalCardFrame: CGRect, zoom: CGFloat) -> CGRect {
        GraphReadableCardScale.frame(for: normalCardFrame, zoom: zoom,
                                     displayScale: displayScale(for: zoom))
    }
}
