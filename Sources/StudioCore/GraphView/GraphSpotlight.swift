import CoreGraphics

/// Emphasis changes contrast, never the scope or hit targets of the graph.
struct GraphSpotlight: Equatable {
    let subjects: Set<String>
    let related: Set<String>
    let pointed: String?

    var isActive: Bool { !subjects.isEmpty }

    func tableOpacity(_ id: String) -> Double {
        guard isActive else { return 1 }
        if subjects.contains(id) || pointed == id { return 1 }
        return related.contains(id) ? 0.62 : 0.24
    }

    func edgeOpacity(source: String, target: String) -> Double {
        guard isActive else { return 1 }
        if subjects.contains(source) && subjects.contains(target) { return 1 }
        if subjects.contains(source) || subjects.contains(target) { return 0.78 }
        if pointed == source || pointed == target { return 0.78 }
        return 0.16
    }
}

@MainActor
enum GraphSpotlightLayout {
    static func footprint(for id: String, cardSize: CGSize, readableRootID: String?, zoom: CGFloat,
                          sizing: GraphNodeSizeProfile, enlargedIDs: Set<String> = []) -> CGSize {
        let zoom = max(0.005, zoom.isFinite ? zoom : 1)
        var size = sizing.layoutSize(for: id, cardSize: cardSize, minimumZoom: zoom)
        if id == readableRootID {
            let scale = GraphReadableCardScale.focusedScale(for: zoom) / zoom
            size.width = max(size.width, cardSize.width * scale * GraphHoverPresentation.detailScale)
            size.height = max(size.height, cardSize.height * scale * GraphHoverPresentation.detailScale)
        } else if enlargedIDs.contains(id) {
            let scale = GraphOverviewAnchors.displayScale(for: zoom) / zoom
            size.width = max(size.width, cardSize.width * scale * GraphHoverPresentation.detailScale)
            size.height = max(size.height, cardSize.height * scale * GraphHoverPresentation.detailScale)
        }
        return size
    }

    /// Grow a card in its existing place and move only neighbours lacking clearance.
    /// The temporary map leaves the overview and the reader's pin state intact.
    static func positions(
        _ positions: [String: CGPoint], cardSizes: [String: CGSize],
        expandedIDs: Set<String>, readableRootID: String?, zoom: CGFloat,
        sizing: GraphNodeSizeProfile = .uniform, enlargedIDs: Set<String> = []
    ) -> [String: CGPoint] {
        let footprints = Dictionary(uniqueKeysWithValues: cardSizes.map { id, cardSize in
            (id, footprint(for: id, cardSize: cardSize, readableRootID: readableRootID, zoom: zoom,
                           sizing: sizing, enlargedIDs: enlargedIDs))
        })
        return LargeGraphLayout.separatingNodes(positions, sizes: footprints,
                                               preferredAnchors: expandedIDs, gap: 40)
    }
}
