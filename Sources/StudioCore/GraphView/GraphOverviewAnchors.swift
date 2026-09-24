import CoreGraphics

/// Important overview tables use the same full card as other tables, but shrink
/// more slowly while the surrounding catalog turns into compact markers.
enum GraphOverviewAnchors {
    struct Anchor: Hashable {
        let id: String
    }

    static let minimumZoom: CGFloat = 0.10
    static let cardTransitionZoom: CGFloat = 0.78
    private static let readableZoom: CGFloat = 0.20
    private static let readableScale: CGFloat = 0.70

    static func displayScale(for zoom: CGFloat) -> CGFloat {
        guard zoom < cardTransitionZoom else { return zoom }
        if zoom <= readableZoom { return zoom * readableScale / readableZoom }
        let progress = (zoom - readableZoom) / (cardTransitionZoom - readableZoom)
        return readableScale + (cardTransitionZoom - readableScale) * progress
    }

    static func frame(for normalCardFrame: CGRect, zoom: CGFloat) -> CGRect {
        guard zoom > 0 else { return normalCardFrame }
        let ratio = displayScale(for: zoom) / zoom
        let width = normalCardFrame.width * ratio
        let height = normalCardFrame.height * ratio
        return CGRect(x: normalCardFrame.midX - width / 2,
                      y: normalCardFrame.midY - height / 2,
                      width: width, height: height)
    }
}
