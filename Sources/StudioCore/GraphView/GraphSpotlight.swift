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
    static func focusedPositions(
        _ positions: [String: CGPoint], cardSizes: [String: CGSize], rootID: String,
        summarySizes: [String: CGSize], zoom: CGFloat, viewportWidth: CGFloat,
        sizing: GraphNodeSizeProfile, manuallyPlacedNodes: [String: CGPoint]
    ) -> [String: CGPoint] {
        let zoom = max(0.005, zoom)
        var positions = positions.merging(manuallyPlacedNodes.filter { positions[$0.key] != nil }) { _, manual in manual }
        let focusIDs = Set(summarySizes.keys).union([rootID])
        var sizes = cardSizes
        for (id, size) in cardSizes {
            sizes[id] = sizing.layoutSize(for: id, cardSize: size, minimumZoom: zoom)
        }
        for (id, size) in summarySizes { sizes[id] = CGSize(width: size.width / zoom, height: size.height / zoom) }
        if let root = cardSizes[rootID] {
            let scale = GraphReadableCardScale.focusedScale(for: zoom, viewportWidth: viewportWidth) / zoom
            let lane = GraphFocusSummaryLayout.edgeLane(rootWidth: root.width * scale * zoom, viewportWidth: viewportWidth)
            let padding = 2 * (lane - 8) / zoom
            sizes[rootID] = CGSize(width: root.width * scale + padding, height: root.height * scale + padding)
        }
        // Resolve manual drops within the focus first, then keep those cards fixed
        // while moving background nodes clear. Catalog density cannot scatter them.
        // Leave two scaled points below the generated gaps: rounding at a shared
        // boundary must not start a chain that pushes a neighbour out of its column.
        let summaryScale = min(1, summarySizes.values.map { $0.height / GraphFocusSummaryLayout.rowHeight }.min() ?? 1)
        let focused = LargeGraphLayout.separatingNodes(positions.filter { focusIDs.contains($0.key) },
            sizes: sizes, preferredAnchors: Set([rootID]).union(manuallyPlacedNodes.keys), gap: 6 * summaryScale / zoom)
        positions.merge(focused) { _, focus in focus }
        return LargeGraphLayout.separatingNodes(positions, sizes: sizes, gap: 8 / zoom, fixedIDs: focusIDs)
    }

    static func footprint(for id: String, cardSize: CGSize, readableRootID: String?, zoom: CGFloat,
                          sizing: GraphNodeSizeProfile, enlargedIDs: Set<String> = [],
                          viewportWidth: CGFloat? = nil) -> CGSize {
        let zoom = max(0.005, zoom.isFinite ? zoom : 1)
        var size = sizing.layoutSize(for: id, cardSize: cardSize, minimumZoom: zoom)
        if id == readableRootID {
            let scale = GraphReadableCardScale.focusedScale(for: zoom, viewportWidth: viewportWidth) / zoom
            size.width = max(size.width, cardSize.width * scale * GraphHoverPresentation.clearanceScale)
            size.height = max(size.height, cardSize.height * scale * GraphHoverPresentation.clearanceScale)
        } else if enlargedIDs.contains(id) {
            let scale = GraphOverviewAnchors.displayScale(for: zoom) / zoom
            size.width = max(size.width, cardSize.width * scale * GraphHoverPresentation.clearanceScale)
            size.height = max(size.height, cardSize.height * scale * GraphHoverPresentation.clearanceScale)
        }
        return size
    }

    /// Grow a card in its existing place and move only neighbours lacking clearance.
    /// The temporary map leaves the overview and the reader's pin state intact.
    static func positions(
        _ positions: [String: CGPoint], cardSizes: [String: CGSize],
        expandedIDs: Set<String>, readableRootID: String?, zoom: CGFloat,
        sizing: GraphNodeSizeProfile = .uniform, enlargedIDs: Set<String> = [],
        manuallyPlacedNodes: [String: CGPoint] = [:]
    ) -> [String: CGPoint] {
        // Focus arrangements can be regenerated for a new zoom or viewport.
        // Keep the reader's dragged locations while still resolving collisions.
        let positions = positions.merging(manuallyPlacedNodes.filter { positions[$0.key] != nil }) { _, manual in manual }
        let zoom = max(0.005, zoom.isFinite ? zoom : 1)
        let inspectedIDs = expandedIDs.union(enlargedIDs).union([readableRootID].compactMap { $0 })
        // Only inspected cards reserve a screen-sized corridor. Giving every
        // compact overview mark fixed screen padding would prevent a large
        // catalog from fitting. Background pairs retain the normal world gap.
        let inspectionPadding = max(0, GraphCardClearance.inspectionScreenGap / zoom
                                    - GraphCardClearance.minimumGap)
        let footprints = Dictionary(uniqueKeysWithValues: cardSizes.map { id, cardSize in
            var size = footprint(for: id, cardSize: cardSize, readableRootID: readableRootID, zoom: zoom,
                                 sizing: sizing, enlargedIDs: enlargedIDs)
            if inspectedIDs.contains(id) {
                size.width += 2 * inspectionPadding
                size.height += 2 * inspectionPadding
            }
            return (id, size)
        })
        return LargeGraphLayout.separatingNodes(positions, sizes: footprints,
                                               preferredAnchors: inspectedIDs.union(manuallyPlacedNodes.keys),
                                               gap: GraphCardClearance.minimumGap)
    }
}
