import AppKit
import SwiftUI

public struct SchemaGraphView: View {
    @Bindable private var session: AppSession
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var viewportRestorePoint: GraphViewportTransform?
    @State private var viewportRestoreNodeID: String?
    @State private var hasPerformedSettledInitialLayout = false
    @State private var nodeDragOrigin: CGPoint?
    @State private var nodeDragPointerOffset: CGSize?
    @State private var multiNodeDragOrigins: [String: CGPoint] = [:]
    @State private var draggedNodeID: String?
    @State private var hoveredNodeID: String?
    @State private var hoveredRelationTarget: GraphRelationHoverTarget?
    @State private var hoveredEdgeID: String?
    @State private var hoveredEdgeMidpoints: [String: CGPoint] = [:]
    @State private var activeRelationHoverTargets: [GraphRelationHoverSource: GraphRelationHoverTarget] = [:]
    @State private var clearRelationHoverTasks: [GraphRelationHoverSource: Task<Void, Never>] = [:]
    @State private var clearNodeHoverTask: Task<Void, Never>?
    @State private var layoutRevision = 0
    @State private var pendingExpansionNodeID: String?
    @State private var selectionRectStart: CGPoint?
    @State private var selectionRectCurrent: CGPoint?
    @State private var isShiftPressed = false
    @State private var showCardinals = true
    @State private var isFeaturesOpen = false
    @State private var haloCache = HaloCache()
    @State private var descriptionHover: DescriptionHover? = nil
    @State private var cardScrollOffsets: [String: CGFloat] = [:]
    @State private var scrollTargetCardID: String? = nil
    @State private var pulledGraphPositions: [String: CGPoint] = [:]
    @State private var tappedRelationTarget: GraphRelationHoverTarget? = nil

    public init(session: AppSession) {
        self.session = session
    }

    private var presentationMode: GraphPresentationMode {
        session.showAllGraphTableCards ? .allCards : .compact
    }

    private var focusNodeID: String? {
        guard hoveredRelationTarget == nil else { return nil }
        if session.showAllGraphTableCards {
            return hoveredNodeID ?? (session.selectedGraphNodeIDs.count <= 1 ? session.selectedGraphNodeID : nil)
        }
        return manuallyExpandedNodeID ?? hoveredNodeID ?? (session.selectedGraphNodeIDs.count <= 1 ? session.selectedGraphNodeID : nil)
    }

    private var manuallyExpandedNodeID: String? {
        session.expandedGraphNodeIDs.sorted().first
    }

    private var relatedPreviewByNode: [String: GraphNodeRelationPreview] {
        guard let manuallyExpandedNodeID, !session.showAllGraphTableCards else { return [:] }

        var previews: [String: GraphNodeRelationPreview] = [:]
        for edge in session.graph.edges where edge.sourceID == manuallyExpandedNodeID || edge.targetID == manuallyExpandedNodeID {
            if edge.sourceID == manuallyExpandedNodeID, edge.targetID != manuallyExpandedNodeID {
                previews[edge.targetID, default: .empty].primaryKeyColumns.insert(edge.targetColumn)
            }
            if edge.targetID == manuallyExpandedNodeID, edge.sourceID != manuallyExpandedNodeID {
                previews[edge.sourceID, default: .empty].foreignKeyColumns.insert(edge.sourceColumn)
            }
        }

        return previews
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                graphBackground

                if session.graph.nodes.isEmpty {
                    emptyState
                } else {
                    graphScene(size: geometry.size)
                    graphOverlayControls(size: geometry.size)
                }
            }
            .onAppear {
                viewportSize = geometry.size
                StudioLog.graph.debug("SchemaGraphView.onAppear settled=\(session.graphLayout.hasSettledLayout, privacy: .public) maximized=\(String(describing: session.maximizedPaneSide), privacy: .public)")
                // If layout is already settled (e.g. remount from fullscreen toggle),
                // restore the saved viewport instead of re-fitting.
                if session.graphLayout.hasRestoredSnapshot || session.graphLayout.hasSettledLayout {
                    Task { @MainActor in
                        zoom = session.graphZoom
                        baseZoom = session.graphZoom
                        pan = session.graphPan
                        panStart = session.graphPan
                    }
                    return
                }
                Task { @MainActor in
                    performInitialLayout(in: geometry.size)
                    guard !hasPerformedSettledInitialLayout else { return }
                    hasPerformedSettledInitialLayout = true
                    performInitialLayout(in: geometry.size)
                }
            }
            .onChange(of: geometry.size) { oldSize, newSize in
                viewportSize = newSize
                if !session.graph.nodes.isEmpty, oldSize == .zero, newSize != .zero, shouldAutoFit {
                    fitGraph(in: newSize)
                }
            }
            .onChange(of: session.graph) { _, _ in
                Task { @MainActor in
                    performInitialLayout(in: geometry.size)
                }
            }
            .onChange(of: session.showAllGraphTableCards) { _, isPresented in
                viewportRestorePoint = nil
                viewportRestoreNodeID = nil
                pendingExpansionNodeID = nil
                hoveredNodeID = nil
                clearRelationHoverState()
                switchPresentationMode(isShowingAllCards: isPresented, in: geometry.size)
            }
            .onChange(of: zoom) { _, newZoom in
                Task { @MainActor in session.graphZoom = newZoom }
            }
            .onChange(of: pan) { _, newPan in
                Task { @MainActor in session.graphPan = newPan }
            }
        }
    }

    private var graphBackground: some View {
        LinearGradient(
            colors: [
                StudioPalette.tablePaneTop,
                StudioPalette.tablePaneBottom,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34))
                .foregroundStyle(StudioPalette.secondaryText)
            Text("Open a SQLite database to inspect declared foreign keys.")
                .foregroundStyle(StudioPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func graphScene(size: CGSize) -> some View {
        let anchorMap = viewportAnchorMap(in: size)
        let currentFocusNodeID = focusNodeID
        let currentHoverTarget = tappedRelationTarget ?? hoveredRelationTarget
        let relationHighlight = GraphRelationHighlight(
            graph: session.graph,
            focusNodeID: currentFocusNodeID,
            hoverTarget: currentHoverTarget
        )
        let edgeLookup = GraphEdgeLookup(edges: session.graph.edges)
        let renderedNodes = renderedGraphNodes(anchorMap: anchorMap, viewportSize: size)
        let _ = layoutRevision

        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(backgroundPanGesture)
                .onTapGesture {
                    if !pulledGraphPositions.isEmpty {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                            pulledGraphPositions.removeAll()
                        }
                        tappedRelationTarget = nil
                    }
                    if let expandedID = manuallyExpandedNodeID {
                        toggleExpandedState(for: expandedID, in: viewportSize)
                    }
                    session.clearGraphSelection()
                    withAnimation(.snappy(duration: 0.18)) {
                        isFeaturesOpen = false
                    }
                }

            GraphTrackpadInputSurface(
                onPan: { delta in
                    applyTrackpadPan(delta)
                },
                onMagnify: { magnification, anchor in
                    applyTrackpadMagnification(magnification, anchor: anchor, in: size)
                },
                onPointerMove: { point in
                    handleViewportPointerMove(point, anchorMap: anchorMap, edgeLookup: edgeLookup)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            Canvas { context, canvasSize in
                drawClusterHalos(in: &context, canvasSize: canvasSize)
            }
            .allowsHitTesting(false)

            Canvas { context, _ in
                drawEdges(in: &context, anchorMap: anchorMap, relationHighlight: relationHighlight)
            }
            .allowsHitTesting(false)

            ForEach(renderedNodes) { node in
                let descriptor = session.descriptor(named: node.id)
                let outgoingEdges = edgeLookup.outgoingEdges(for: node.id)
                let incomingEdges = edgeLookup.incomingEdges(for: node.id)
                let previewColumns = previewColumns(for: node.id)
                let displayStyle = nodeDisplayStyle(for: node.id, previewColumns: previewColumns)
                let cardSize = nodeSize(for: node.id)
                let scrollOffset = cardScrollOffsets[node.id] ?? 0

                GraphNodeCardView(
                    node: node,
                    descriptor: descriptor,
                    tableDescription: session.tableDescription(for: node.id),
                    clusterLabel: session.clusterLabel(for: node.id),
                    columnDescription: { session.columnDescription(for: node.id, column: $0) },
                    previewColumns: previewColumns,
                    outgoingEdges: outgoingEdges,
                    incomingEdges: incomingEdges,
                    isSelected: session.selectedGraphNodeIDs.contains(node.id),
                    displayStyle: displayStyle,
                    scrollOffset: scrollOffset,
                    isHovered: hoveredNodeID == node.id,
                    isDragging: draggedNodeID == node.id,
                    highlightState: relationHighlight.highlightState(for: node.id),
                    selectNode: {
                        if !pulledGraphPositions.isEmpty {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                                pulledGraphPositions.removeAll()
                            }
                            tappedRelationTarget = nil
                        }
                        withAnimation(.snappy(duration: 0.16)) {
                            session.selectGraphNode(node.id)
                        }
                    },
                    toggleExpanded: {
                        toggleExpandedState(for: node.id, in: size)
                    },
                    openTable: {
                        withAnimation(.snappy(duration: 0.16)) {
                            session.selectGraphNode(node.id)
                        }
                        _ = session.openTable(named: node.id)
                    },
                    showTopRows: {
                        withAnimation(.snappy(duration: 0.16)) {
                            session.selectGraphNode(node.id)
                        }
                        session.runTopRowsQuery(for: node.id)
                    },
                    usesViewportHoverTracking: true,
                    hoverChanged: { isHovered in
                        handleHoverChange(isHovered, for: node.id)
                    },
                    relationHoverChanged: { target, source, isHovered in
                        handleRelationHoverChange(target, source: source, isHovered: isHovered)
                    },
                    relationTapped: { target in
                        pullConnectedNodesIntoView(for: target)
                    },
                    headerDragGesture: nodeDragGesture(nodeID: node.id, in: size)
                )
                .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
                .scaleEffect(zoom)
                .position(screenCenter(for: node.id, in: size))
                .shadow(
                    color: StudioPalette.shadow.opacity(session.showAllGraphTableCards ? 0.38 : 0.8),
                    radius: shadowRadius(for: node.id),
                    y: session.showAllGraphTableCards ? 5 : (draggedNodeID == node.id ? 16 : 10)
                )
                .zIndex(zIndex(for: node.id))
            }
            
            // Floating description tooltip
            if let hover = descriptionHover {
                descriptionTooltip(hover, in: size)
                    .zIndex(9000)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                    .animation(.snappy(duration: 0.15), value: descriptionHover)
            }

            // Selection rectangle visualization
            if let start = selectionRectStart, let current = selectionRectCurrent {
                let rect = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                Rectangle()
                    .stroke(StudioPalette.accent, lineWidth: 2)
                    .background(StudioPalette.accent.opacity(0.1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .zIndex(1000)
            }

            // Cardinality labels are drawn directly in the Canvas (see drawEdges)
        }
        .coordinateSpace(name: "graphViewport")
        .animation(session.showAllGraphTableCards ? nil : .snappy(duration: 0.18), value: session.expandedGraphNodeIDs)
        .animation(.snappy(duration: 0.18), value: session.showAllGraphTableCards)
    }

    /// Renders a faded color "halo" behind each cluster declared in the sidecar. Shape is
    /// the convex hull of cluster member positions, expanded outward by a card-half-width
    /// pad so the cards sit inside the colored region, then smoothed with quadratic curves
    /// for an organic look. Drawn under edges and nodes so they never obscure content.
    private func drawClusterHalos(in context: inout GraphicsContext, canvasSize: CGSize) {
        guard session.showClusterHalos else { return }
        guard !session.graphLayout.isAnimating else { return }
        let clusters = session.schemaSidecar.clusters
        guard !clusters.isEmpty else { return }

        // Rebuild union paths in graph space only when positions change.
        // Pan/zoom are applied cheaply via affine transform at render time.
        if haloCache.layoutRevision != layoutRevision {
            let pad: CGFloat = 22  // graph-space padding around each card

            haloCache.entries = clusters.compactMap { cluster in
                guard let color = Color(studioHex: cluster.color ?? "") else { return nil }
                var merged: Path? = nil
                for name in cluster.tables {
                    guard session.graph.contains(nodeID: name) else { continue }
                    let pt = session.graphLayout.position(for: name)
                    let sz = nodeSize(for: name)
                    let hw = sz.width  / 2 + pad
                    let hh = sz.height / 2 + pad
                    let rect = CGRect(x: pt.x - hw, y: pt.y - hh, width: hw * 2, height: hh * 2)
                    let bubble = Path(roundedRect: rect, cornerRadius: hh)
                    merged = merged.map { $0.union(bubble) } ?? bubble
                }
                guard let path = merged else { return nil }
                return HaloCache.Entry(color: color, path: path, label: cluster.label)
            }
            haloCache.layoutRevision = layoutRevision
        }

        // Cheap affine transform: graph space → screen space
        let viewportTransform = CGAffineTransform(scaleX: zoom, y: zoom)
            .concatenating(CGAffineTransform(
                translationX: canvasSize.width / 2 + pan.width,
                y: canvasSize.height / 2 + pan.height
            ))

        // Thicker when zoomed out so borders stay visible; thinner when zoomed in
        // so they don't compete with the cards themselves.
        let lineWidth: CGFloat = max(1.0, min(3.5, 2.0 / zoom))

        for entry in haloCache.entries {
            let screenPath = entry.path.applying(viewportTransform)
            context.stroke(
                screenPath,
                with: .color(entry.color.opacity(0.65)),
                style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)
            )
            if let label = entry.label, !label.isEmpty {
                let bounds = screenPath.boundingRect
                let labelPoint = CGPoint(x: bounds.midX, y: bounds.minY - 6)
                let resolved = context.resolve(
                    Text(label.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(entry.color.opacity(0.85))
                )
                context.draw(resolved, at: labelPoint, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func descriptionTooltip(_ hover: DescriptionHover, in canvasSize: CGSize) -> some View {
        let tooltipMaxWidth: CGFloat = 230
        let nodeCenter = screenCenter(for: hover.nodeID, in: canvasSize)
        let scaledCardW = nodeSize(for: hover.nodeID).width * zoom
        let scaledCardH = nodeSize(for: hover.nodeID).height * zoom
        let gap: CGFloat = 10

        // Prefer right side; fall back to left if tooltip would clip the edge.
        let rightEdge = nodeCenter.x + scaledCardW / 2 + gap + tooltipMaxWidth
        let useRight = rightEdge < canvasSize.width - 8
        let anchorX = useRight
            ? nodeCenter.x + scaledCardW / 2 + gap
            : nodeCenter.x - scaledCardW / 2 - gap - tooltipMaxWidth
        // Clamp vertically so the panel stays inside the viewport.
        let anchorY = max(6, min(canvasSize.height - 6, nodeCenter.y - scaledCardH / 4))

        VStack(alignment: .leading, spacing: 5) {
            if let col = hover.column {
                Text(col)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(StudioPalette.secondaryText)
            }
            Text(hover.text)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: tooltipMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StudioPalette.borderSoft, lineWidth: 1)
        )
        .frame(maxWidth: tooltipMaxWidth, alignment: .leading)
        .position(x: anchorX + tooltipMaxWidth / 2, y: anchorY)
    }

    private func drawEdges(
        in context: inout GraphicsContext,
        anchorMap: GraphAnchorMap,
        relationHighlight: GraphRelationHighlight
    ) {
        for edge in session.graph.edges {
            guard let anchors = anchorMap.edgeAnchors(for: edge) else { continue }

            let isHighlighted = relationHighlight.highlightedEdgeIDs.contains(edge.id)
            let path = edgePath(from: anchors.source, to: anchors.target)
            let strokeColor = isHighlighted
                ? StudioPalette.edgeHighlight
                : StudioPalette.edgeNeutral.opacity(session.showAllGraphTableCards ? 0.48 : 0.34)

            if isHighlighted {
                context.stroke(
                    path,
                    with: .color(StudioPalette.edgeHighlight.opacity(0.12)),
                    style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round)
                )
            }

            context.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(
                    lineWidth: isHighlighted ? 1.85 : (session.showAllGraphTableCards ? 1.25 : 1.05),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            
            if isHighlighted {
                let (control1, control2) = edgeControlPoints(from: anchors.source, to: anchors.target)
                drawDirectionMarker(in: &context, from: anchors.source, control1: control1, control2: control2, to: anchors.target, color: StudioPalette.edgeHighlight)
                if showCardinals {
                    drawCardinalityLabels(in: &context, edge: edge, start: anchors.source, control1: control1, control2: control2, end: anchors.target)
                }
            }
        }
    }

    private func drawDirectionMarker(
        in context: inout GraphicsContext,
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        color: Color
    ) {
        let tangent = bezierTangent(start: start, control1: control1, control2: control2, end: end, t: 0.5)
        let dx = tangent.dx
        let dy = tangent.dy
        guard dx != 0 || dy != 0 else { return }

        let angle = atan2(dy, dx)
        let markerCenter = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 0.5)
        let markerSize: CGFloat = 4.8
        let markerAngle: CGFloat = .pi / 5

        var path = Path()
        path.move(to: CGPoint(
            x: markerCenter.x - markerSize * cos(angle - markerAngle),
            y: markerCenter.y - markerSize * sin(angle - markerAngle)
        ))
        path.addLine(to: markerCenter)
        path.addLine(to: CGPoint(
            x: markerCenter.x - markerSize * cos(angle + markerAngle),
            y: markerCenter.y - markerSize * sin(angle + markerAngle)
        ))

        context.stroke(
            path,
            with: .color(color.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawCardinalityLabels(
        in context: inout GraphicsContext,
        edge: GraphEdge,
        start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        end: CGPoint
    ) {
        let (sourceSymbol, targetSymbol): (String, String) = {
            switch edge.cardinality {
            case .oneToOne:   return ("1", "1")
            case .oneToMany:  return ("1", "*")
            case .manyToOne:  return ("*", "1")
            case .manyToMany: return ("*", "*")
            }
        }()

        let sourcePoint = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 0.18)
        let targetPoint = bezierPoint(start: start, control1: control1, control2: control2, end: end, t: 0.82)

        let labelFont = Font.system(size: 11, weight: .bold, design: .monospaced)
        let strokeColor = Color.white
        let fillColor = Color.black

        // Draw white stroke by offsetting copies in 8 directions
        let offsets: [(CGFloat, CGFloat)] = [
            (-1, -1), (0, -1), (1, -1),
            (-1,  0),          (1,  0),
            (-1,  1), (0,  1), (1,  1),
        ]
        for (dx, dy) in offsets {
            let strokeText = Text(sourceSymbol).font(labelFont).foregroundStyle(strokeColor)
            context.draw(strokeText, at: CGPoint(x: sourcePoint.x + dx, y: sourcePoint.y + dy), anchor: .center)
            let strokeText2 = Text(targetSymbol).font(labelFont).foregroundStyle(strokeColor)
            context.draw(strokeText2, at: CGPoint(x: targetPoint.x + dx, y: targetPoint.y + dy), anchor: .center)
        }

        let sourceText = Text(sourceSymbol).font(labelFont).foregroundStyle(fillColor)
        let targetText = Text(targetSymbol).font(labelFont).foregroundStyle(fillColor)

        context.draw(sourceText, at: sourcePoint, anchor: .center)
        context.draw(targetText, at: targetPoint, anchor: .center)
    }

    private func edgeControlPoints(from start: CGPoint, to end: CGPoint) -> (control1: CGPoint, control2: CGPoint) {
        let horizontalDelta = end.x - start.x
        let controlOffset = max(32, abs(horizontalDelta) * 0.34)
        let control1 = CGPoint(
            x: start.x + (horizontalDelta >= 0 ? controlOffset : -controlOffset),
            y: start.y
        )
        let control2 = CGPoint(
            x: end.x - (horizontalDelta >= 0 ? controlOffset : -controlOffset),
            y: end.y
        )
        return (control1, control2)
    }

    private func edgePath(from start: CGPoint, to end: CGPoint) -> Path {
        let (control1, control2) = edgeControlPoints(from: start, to: end)

        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    private func edgeMidpoint(for edge: GraphEdge, anchorMap: GraphAnchorMap) -> CGPoint {
        guard let anchors = anchorMap.edgeAnchors(for: edge) else {
            return .zero
        }
        let (control1, control2) = edgeControlPoints(from: anchors.source, to: anchors.target)
        return bezierPoint(start: anchors.source, control1: control1, control2: control2, end: anchors.target, t: 0.5)
    }

    private func graphOverlayControls(size: CGSize) -> some View {
        ZStack {
            // Main controls (top right)
            VStack(alignment: .trailing, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    // Features button with flyout menu
                    FeaturesMenuButton(
                        isOpen: $isFeaturesOpen,
                        showCardinals: $showCardinals,
                        showClusterHalos: Binding(
                            get: { session.showClusterHalos },
                            set: { session.showClusterHalos = $0 }
                        ),
                        hasClusters: !session.schemaSidecar.clusters.isEmpty
                    )

                    Button {
                        // Pick up any edits to the sidecar (new clusters, renamed groups)
                        // and wipe the cached layout so stale positions from earlier app
                        // builds can't get restored on top of fresh cluster geometry.
                        session.reloadSchemaSidecarFromDisk()
                        session.clearPersistedGraphLayout()
                        rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
                    } label: {
                        Label("Relayout", systemImage: "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(StudioPalette.accent)
                    .help("Reload cluster hints & rebuild the layout from scratch")
                }

                Toggle(
                    "Show All Table Cards",
                    isOn: Binding(
                        get: { session.showAllGraphTableCards },
                        set: { session.setShowAllGraphTableCards($0) }
                    )
                )
                .toggleStyle(.switch)
                .font(.subheadline)
                .foregroundStyle(StudioPalette.primaryText)
                .help("Show all table cards")
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StudioPalette.chromeFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(StudioPalette.border, lineWidth: 1)
            }
            .shadow(color: StudioPalette.shadow.opacity(0.75), radius: 18, y: 12)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            
            // Back to Content button (center, shown when no nodes visible)
            if shouldShowBackToContent(in: size) {
                Button {
                    fitGraph(in: size)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Back to Content")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(StudioPalette.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(StudioPalette.chromeFill))
                .overlay { Capsule().stroke(StudioPalette.border, lineWidth: 1) }
                .shadow(color: StudioPalette.shadow.opacity(0.75), radius: 18, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
    
    private func shouldShowBackToContent(in size: CGSize) -> Bool {

        // Check if any nodes are visible in the current viewport
        let transform = GraphViewportTransform(zoom: zoom, pan: pan)
        let viewportRect = CGRect(origin: .zero, size: size)
        
        for node in session.graph.nodes {
            let nodePos = session.graphLayout.position(for: node.id)
            let screenPos = transform.point(for: nodePos, in: size)
            
            // Add some margin for node size
            let margin: CGFloat = 200
            let expandedViewport = viewportRect.insetBy(dx: -margin, dy: -margin)
            
            if expandedViewport.contains(screenPos) {
                return false
            }
        }
        
        return true
    }
    
    private func graphContentBounds() -> CGRect {
        guard !session.graph.nodes.isEmpty else { return .zero }
        
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        
        for node in session.graph.nodes {
            let pos = session.graphLayout.position(for: node.id)
            minX = min(minX, pos.x)
            minY = min(minY, pos.y)
            maxX = max(maxX, pos.x)
            maxY = max(maxY, pos.y)
        }
        
        let padding: CGFloat = 100
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2
        )
    }

    private func renderedGraphNodes(anchorMap: GraphAnchorMap, viewportSize: CGSize) -> [GraphNode] {
        guard session.showAllGraphTableCards else { return session.graph.nodes }

        let renderViewport = CGRect(origin: .zero, size: viewportSize).insetBy(dx: -420, dy: -420)
        return session.graph.nodes.filter { node in
            if node.id == draggedNodeID || node.id == hoveredNodeID || session.selectedGraphNodeIDs.contains(node.id) {
                return true
            }

            guard let frame = anchorMap.nodeCards[node.id]?.frame else {
                return true
            }

            return frame.intersects(renderViewport)
        }
    }

    private func shadowRadius(for nodeID: String) -> CGFloat {
        if draggedNodeID == nodeID {
            return session.showAllGraphTableCards ? 14 : 26
        }
        if session.showAllGraphTableCards {
            return hoveredNodeID == nodeID ? 8 : 3
        }
        return 12
    }

    private var backgroundPanGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graphViewport"))
            .onChanged { value in
                guard draggedNodeID == nil else { return }
                
                // Check if shift is pressed for selection rectangle
                if NSEvent.modifierFlags.contains(.shift) {
                    if selectionRectStart == nil {
                        selectionRectStart = value.startLocation
                    }
                    selectionRectCurrent = value.location
                    updateSelectionFromRect(in: viewportSize)
                } else {
                    // Normal panning
                    pan = CGSize(
                        width: panStart.width + value.translation.width,
                        height: panStart.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                guard draggedNodeID == nil else { return }
                
                if selectionRectStart != nil {
                    // Finish selection
                    selectionRectStart = nil
                    selectionRectCurrent = nil
                } else {
                    panStart = pan
                }
            }
    }
    
    private func updateSelectionFromRect(in canvasSize: CGSize) {
        guard let start = selectionRectStart, let current = selectionRectCurrent else { return }
        
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        
        var selectedNodes: Set<String> = []
        let transform = GraphViewportTransform(zoom: zoom, pan: pan)
        
        for node in session.graph.nodes {
            let nodePos = session.graphLayout.position(for: node.id)
            let screenPos = transform.point(for: nodePos, in: canvasSize)
            
            if rect.contains(screenPos) {
                selectedNodes.insert(node.id)
            }
        }
        
        session.setGraphSelection(selectedNodes)
    }

    private func nodeDragGesture(nodeID: String, in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("graphViewport"))
            .onChanged { value in
                if draggedNodeID != nodeID {
                    draggedNodeID = nodeID
                    nodeDragOrigin = session.graphLayout.position(for: nodeID)
                    let startGraphPoint = GraphViewportTransform(zoom: zoom, pan: pan)
                        .graphPoint(for: value.startLocation, in: canvasSize)
                    if let nodeDragOrigin {
                        nodeDragPointerOffset = CGSize(
                            width: startGraphPoint.x - nodeDragOrigin.x,
                            height: startGraphPoint.y - nodeDragOrigin.y
                        )
                    }
                    hoveredNodeID = nil
                    clearRelationHoverState()
                    if !pulledGraphPositions.isEmpty { pulledGraphPositions.removeAll() }
                    tappedRelationTarget = nil
                    
                    // If node is not in selection, select only this node
                    if !session.selectedGraphNodeIDs.contains(nodeID) {
                        session.selectGraphNode(nodeID)
                    }
                    multiNodeDragOrigins = Dictionary(
                        uniqueKeysWithValues: session.selectedGraphNodeIDs.map { ($0, session.graphLayout.position(for: $0)) }
                    )
                }

                guard draggedNodeID == nodeID else { return }
                let currentGraphPoint = GraphViewportTransform(zoom: zoom, pan: pan)
                    .graphPoint(for: value.location, in: canvasSize)
                let moved = CGPoint(
                    x: currentGraphPoint.x - (nodeDragPointerOffset?.width ?? 0),
                    y: currentGraphPoint.y - (nodeDragPointerOffset?.height ?? 0)
                )
                
                // If multiple nodes selected, move them all together
                if session.selectedGraphNodeIDs.count > 1 {
                    let delta = CGPoint(
                        x: moved.x - (nodeDragOrigin?.x ?? moved.x),
                        y: moved.y - (nodeDragOrigin?.y ?? moved.y)
                    )
                    
                    for selectedNodeID in session.selectedGraphNodeIDs {
                        let originalPos = multiNodeDragOrigins[selectedNodeID] ?? session.graphLayout.position(for: selectedNodeID)
                        let newPos = CGPoint(
                            x: originalPos.x + delta.x,
                            y: originalPos.y + delta.y
                        )
                        session.graphLayout.pin(nodeID: selectedNodeID, at: newPos)
                    }
                } else {
                    session.graphLayout.pin(nodeID: nodeID, at: moved)
                }
                
                layoutRevision &+= 1
            }
            .onEnded { _ in
                draggedNodeID = nil
                nodeDragOrigin = nil
                nodeDragPointerOffset = nil
                multiNodeDragOrigins = [:]
                layoutRevision &+= 1
                if !session.showAllGraphTableCards {
                    session.persistCurrentGraphLayout()
                }
            }
    }

    private func zIndex(for nodeID: String) -> Double {
        if draggedNodeID == nodeID {
            return 4
        }
        if hoveredNodeID == nodeID {
            return 3
        }
        if session.selectedGraphNodeID == nodeID {
            return 2
        }
        if nodeDisplayStyle(for: nodeID) != .collapsed {
            return 1
        }
        return 0
    }

    private func previewColumns(for nodeID: String) -> [TableColumn] {
        guard let descriptor = session.descriptor(named: nodeID),
              let preview = relatedPreviewByNode[nodeID]
        else {
            return []
        }

        let visibleColumnNames = preview.foreignKeyColumns.union(preview.primaryKeyColumns)
        return descriptor.columns.filter { visibleColumnNames.contains($0.name) }
    }

    private func nodeDisplayStyle(for nodeID: String, previewColumns: [TableColumn]? = nil) -> GraphNodeCardStyle {
        if session.showAllGraphTableCards || session.expandedGraphNodeIDs.contains(nodeID) {
            return .expanded
        }

        let resolvedPreviewColumns = previewColumns ?? self.previewColumns(for: nodeID)
        if !resolvedPreviewColumns.isEmpty {
            return .preview(rowCount: resolvedPreviewColumns.count)
        }

        return .collapsed
    }

    private func nodeSize(for nodeID: String) -> CGSize {
        guard let node = session.graph.nodes.first(where: { $0.id == nodeID }) else {
            return CGSize(width: 140, height: GraphCardLayout.collapsedHeight)
        }
        return GraphCardLayout.nodeSize(
            title: node.title,
            descriptor: session.descriptor(named: nodeID),
            style: nodeDisplayStyle(for: nodeID, previewColumns: previewColumns(for: nodeID)),
            hovered: hoveredNodeID == nodeID && draggedNodeID == nil
        )
    }

    private func visibleColumnNames(for nodeID: String) -> [String]? {
        switch nodeDisplayStyle(for: nodeID) {
        case .collapsed:
            return nil
        case .preview:
            return previewColumns(for: nodeID).map(\.name)
        case .expanded:
            // Return only the 7 currently-visible columns (scroll-aware) so rowFrames reflects
            // actual screen positions — used for both edge anchors and hover hit detection.
            let allColumns = session.descriptor(named: nodeID)?.columns ?? []
            let scrollOffset = cardScrollOffsets[nodeID] ?? 0
            let scrollIndex = Int(scrollOffset / GraphCardLayout.expandedRowHeight)
            let endIndex = min(scrollIndex + GraphCardLayout.maxExpandedVisibleRows, allColumns.count)
            return allColumns[scrollIndex..<endIndex].map(\.name)
        }
    }

    private func cardRole(for nodeID: String) -> GraphCardRole {
        switch nodeDisplayStyle(for: nodeID) {
        case .collapsed:
            return .collapsedNode
        case .preview:
            return .previewNode
        case .expanded:
            return .expandedNode
        }
    }

    private func screenCenter(for nodeID: String, in canvasSize: CGSize) -> CGPoint {
        let graphPos = pulledGraphPositions[nodeID] ?? session.graphLayout.position(for: nodeID)
        return GraphViewportTransform(zoom: zoom, pan: pan).point(for: graphPos, in: canvasSize)
    }

    private func viewportAnchorMap(in canvasSize: CGSize) -> GraphAnchorMap {
        let nodeCards = Dictionary(uniqueKeysWithValues: session.graph.nodes.map { node in
            let descriptor = session.descriptor(named: node.id)
            let baseSize = nodeSize(for: node.id)
            let scaledSize = CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
            let center = screenCenter(for: node.id, in: canvasSize)
            let frame = CGRect(
                x: center.x - scaledSize.width / 2,
                y: center.y - scaledSize.height / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )

            return (
                node.id,
                GraphCardGeometry(
                    tableID: node.id,
                    frame: frame,
                    role: cardRole(for: node.id),
                    descriptor: descriptor,
                    displayedColumns: visibleColumnNames(for: node.id),
                    scale: zoom
                )
            )
        })

        return GraphAnchorMap(nodeCards: nodeCards)
    }

    private func graphBoundsAnchorMap() -> GraphAnchorMap {
        let nodeCards = Dictionary(uniqueKeysWithValues: session.graph.nodes.map { node in
            let descriptor = session.descriptor(named: node.id)
            let size = nodeSize(for: node.id)
            let center = session.graphLayout.position(for: node.id)
            let frame = CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            return (
                node.id,
                GraphCardGeometry(
                    tableID: node.id,
                    frame: frame,
                    role: cardRole(for: node.id),
                    descriptor: descriptor,
                    displayedColumns: visibleColumnNames(for: node.id)
                )
            )
        })

        return GraphAnchorMap(nodeCards: nodeCards)
    }

    private func fitGraph(in size: CGSize) {
        setViewport(
            GraphViewportTransform.fit(contentBounds: graphBoundsAnchorMap().contentBounds, in: size),
            animated: true
        )
    }

    /// Crowded graphs (>10 nodes) skip auto-fit so nodes aren't squashed into the viewport.
    /// The user pans/zooms manually and clustering does the visual organization.
    private var shouldAutoFit: Bool {
        session.graph.nodes.count <= GraphLayoutModel.crowdedNodeThreshold
    }

    private func performInitialLayout(in size: CGSize) {
        guard !session.graph.nodes.isEmpty else { return }

        if session.graphLayout.hasRestoredSnapshot || session.graphLayout.hasSettledLayout {
            // Positions are already settled — do not run physics.
            // This covers both restored snapshots and layouts that have already been
            // stabilized in this session (e.g. after toggling full-screen / maximized pane).
            // Only fit the viewport on the very first appearance (size was zero before).
            return
        } else {
            rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
        }
    }

    private func rebuildLayout(in size: CGSize, refit: Bool, clearPinnedState: Bool, persistLayout: Bool) {
        if clearPinnedState {
            session.graphLayout.clearPinnedState()
        }

        session.graphLayout.relayout(
            for: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) }
        )
        session.graphLayout.stabilize(
            graph: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) },
            nodeSizeLookup: { nodeSize(for: $0) },
            maxIterations: presentationMode == .allCards ? 140 : 260
        )
        layoutRevision &+= 1

        if persistLayout, !session.showAllGraphTableCards {
            session.persistCurrentGraphLayout()
        }

        if refit, shouldAutoFit {
            fitGraph(in: size)
        }
    }

    private func switchPresentationMode(isShowingAllCards: Bool, in size: CGSize) {
        // Capture current viewport so we can restore it after the layout switch
        let savedZoom = zoom
        let savedPan = pan

        if isShowingAllCards {
            session.graphLayout.relayoutPreservingCurrentPositions(
                for: session.graph,
                presentation: presentationMode,
                descriptorLookup: { session.descriptor(named: $0) }
            )
            // Use maxIterations: 0 to skip force-directed ticks entirely.
            // Only the post-physics overlap resolution and spread-limiting passes run,
            // which is sufficient to handle the larger card sizes without re-arranging nodes.
            session.graphLayout.stabilize(
                graph: session.graph,
                presentation: presentationMode,
                descriptorLookup: { session.descriptor(named: $0) },
                nodeSizeLookup: { nodeSize(for: $0) },
                maxIterations: 0
            )
            layoutRevision &+= 1
            // Restore the same zoom/pan instead of fitting
            setViewport(GraphViewportTransform(zoom: savedZoom, pan: savedPan), animated: false)
        } else {
            // Restore the saved compact layout — don't stabilize, just refit
            session.restoreCompactGraphLayoutForCurrentDatabase()
            layoutRevision &+= 1
            // Restore the same zoom/pan instead of fitting
            setViewport(GraphViewportTransform(zoom: savedZoom, pan: savedPan), animated: false)
        }
    }

    private func stabilizeLayout(in size: CGSize, refit: Bool, persistLayout: Bool) {
        session.graphLayout.stabilize(
            graph: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) },
            nodeSizeLookup: { nodeSize(for: $0) },
            maxIterations: presentationMode == .allCards ? 140 : 260
        )
        layoutRevision &+= 1

        if persistLayout, !session.showAllGraphTableCards {
            session.persistCurrentGraphLayout()
        }

        if refit, shouldAutoFit {
            fitGraph(in: size)
        }
    }

    private func handleHoverChange(_ isHovered: Bool, for nodeID: String) {
        // This is only called when usesViewportHoverTracking is false.
        // Since we now always use viewport tracking, this is a no-op safety fallback.
        guard draggedNodeID == nil else { return }

        if isHovered {
            clearNodeHoverTask?.cancel()
            clearNodeHoverTask = nil
            withAnimation(.snappy(duration: 0.16)) {
                hoveredNodeID = nodeID
            }
        } else if hoveredNodeID == nodeID {
            clearNodeHoverTask?.cancel()
            clearNodeHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.16)) {
                    if self.hoveredNodeID == nodeID {
                        self.hoveredNodeID = nil
                    }
                }
                self.clearNodeHoverTask = nil
            }
        }
    }

    private func handleViewportPointerMove(
        _ point: CGPoint?,
        anchorMap: GraphAnchorMap,
        edgeLookup: GraphEdgeLookup
    ) {
        guard draggedNodeID == nil, let point else {
            if session.showAllGraphTableCards {
                updateViewportHover(nodeID: nil, relationTarget: nil)
            } else {
                withAnimation(.snappy(duration: 0.16)) { hoveredNodeID = nil }
            }
            updateDescriptionHover(nil, for: "")
            scrollTargetCardID = nil
            return
        }

        guard let card = graphCard(at: point, anchorMap: anchorMap) else {
            if session.showAllGraphTableCards {
                updateViewportHover(nodeID: nil, relationTarget: nil)
            } else {
                withAnimation(.snappy(duration: 0.16)) { hoveredNodeID = nil }
            }
            updateDescriptionHover(nil, for: "")
            scrollTargetCardID = nil
            return
        }

        StudioLog.graph.debug("viewportPointerMove: found card=\(card.tableID, privacy: .public) at point=\(point.x, privacy: .public),\(point.y, privacy: .public) maximized=\(String(describing: session.maximizedPaneSide), privacy: .public)")

        // Determine if cursor is in the scrollable body of an expanded card with >7 columns.
        let totalColumns = session.descriptor(named: card.tableID)?.columns.count ?? 0
        let isScrollableExpanded = card.role == .expandedNode && totalColumns > GraphCardLayout.maxExpandedVisibleRows
        let newScrollTarget: String? = isScrollableExpanded && point.y > card.headerFrame.maxY ? card.tableID : nil
        if scrollTargetCardID != newScrollTarget { scrollTargetCardID = newScrollTarget }

        // rowFrames are scroll-aware (reflect actual screen positions of visible columns),
        // so use the raw point for all hit-detection.
        updateDescriptionHover(descriptionInfo(at: point, in: card), for: card.tableID)

        if session.showAllGraphTableCards {
            let relationTarget = relationHoverTarget(at: point, in: card, edgeLookup: edgeLookup)
            updateViewportHover(nodeID: card.tableID, relationTarget: relationTarget)
        } else {
            // In compact mode, use viewport-based relation hover too (same as allCards),
            // so badge/row hover works even when .scaleEffect breaks SwiftUI .onHover.
            let relationTarget = relationHoverTarget(at: point, in: card, edgeLookup: edgeLookup)
            if let relationTarget {
                // Relation hover — update both nodeID and relation target
                if hoveredNodeID != card.tableID {
                    clearNodeHoverTask?.cancel()
                    clearNodeHoverTask = nil
                    hoveredNodeID = card.tableID
                }
                updateViewportHover(nodeID: card.tableID, relationTarget: relationTarget)
            } else {
                // Plain node hover — only update hoveredNodeID, don't clear relation target
                // (relation target is cleared when pointer leaves the column area)
                updateViewportHover(nodeID: card.tableID, relationTarget: nil)
                if hoveredNodeID != card.tableID {
                    clearNodeHoverTask?.cancel()
                    clearNodeHoverTask = nil
                    withAnimation(.snappy(duration: 0.16)) {
                        hoveredNodeID = card.tableID
                    }
                }
            }
        }
    }

    private struct DescriptionInfo {
        let column: String?
        let text: String
    }

    private func descriptionInfo(at point: CGPoint, in card: GraphCardGeometry) -> DescriptionInfo? {
        // Table name zone: inset + estimated text width (size-13 semibold ≈ 8 layout px/char) + margin.
        let hf = card.headerFrame
        let headerTextMaxX = hf.minX + (14.0 + CGFloat(card.tableID.count) * 8.0 + 22.0) * zoom
        if point.y >= hf.minY && point.y < hf.maxY
            && point.x >= hf.minX
            && point.x < headerTextMaxX {
            let tableDesc = session.tableDescription(for: card.tableID)
            let clusterLabel = session.clusterLabel(for: card.tableID)
            if tableDesc != nil || clusterLabel != nil {
                let text = [clusterLabel.map { "[\($0)]" }, tableDesc]
                    .compactMap { $0 }.joined(separator: " — ")
                return DescriptionInfo(column: nil, text: text)
            }
        }
        // Column name zone: inner padding + estimated text width (size-11 mono ≈ 7.3 layout px/char) + margin.
        if let col = card.columnName(at: point),
           let rowFrame = card.rowFrames[col] {
            let rowTextMaxX = rowFrame.minX + (8.0 + CGFloat(col.count) * 7.3 + 18.0) * zoom
            if point.x < rowTextMaxX,
               let note = session.columnDescription(for: card.tableID, column: col) {
                return DescriptionInfo(column: col, text: note)
            }
        }
        return nil
    }

    private func updateDescriptionHover(_ info: DescriptionInfo?, for nodeID: String) {
        let newHover = info.map { DescriptionHover(nodeID: nodeID, column: $0.column, text: $0.text) }
        guard newHover != descriptionHover else { return }
        if newHover != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        descriptionHover = newHover
    }

    private func graphCard(at point: CGPoint, anchorMap: GraphAnchorMap) -> GraphCardGeometry? {
        var bestHit: (index: Int, zIndex: Double, card: GraphCardGeometry)?

        for (index, node) in session.graph.nodes.enumerated() {
            guard let card = anchorMap.nodeCards[node.id], card.frame.contains(point) else { continue }
            let candidate = (index: index, zIndex: zIndex(for: node.id), card: card)
            if let current = bestHit {
                if candidate.zIndex > current.zIndex || (candidate.zIndex == current.zIndex && candidate.index > current.index) {
                    bestHit = candidate
                }
            } else {
                bestHit = candidate
            }
        }

        return bestHit?.card
    }

    private func relationHoverTarget(
        at point: CGPoint,
        in card: GraphCardGeometry,
        edgeLookup: GraphEdgeLookup
    ) -> GraphRelationHoverTarget? {
        guard let columnName = card.columnName(at: point) else { return nil }
        let hasOutgoingRelation = edgeLookup.outgoingEdges(for: card.tableID).contains { $0.sourceColumn == columnName }
        let hasIncomingRelation = edgeLookup.incomingEdges(for: card.tableID).contains { $0.targetColumn == columnName }
        guard hasOutgoingRelation || hasIncomingRelation else { return nil }

        return GraphRelationHoverTarget(
            tableID: card.tableID,
            columnName: columnName,
            endpointKind: .column
        )
    }

    private func updateViewportHover(nodeID: String?, relationTarget: GraphRelationHoverTarget?) {
        if hoveredNodeID != nodeID {
            hoveredNodeID = nodeID
        }

        guard hoveredRelationTarget != relationTarget else { return }
        for task in clearRelationHoverTasks.values {
            task.cancel()
        }
        clearRelationHoverTasks.removeAll()
        activeRelationHoverTargets.removeAll()
        if let relationTarget {
            let source = GraphRelationHoverSource(
                tableID: relationTarget.tableID,
                columnName: relationTarget.columnName,
                area: .row
            )
            activeRelationHoverTargets[source] = relationTarget
        }
        hoveredRelationTarget = relationTarget
    }

    private func handleRelationHoverChange(
        _ target: GraphRelationHoverTarget,
        source: GraphRelationHoverSource,
        isHovered: Bool
    ) {
        guard draggedNodeID == nil else { return }

        StudioLog.graph.debug("relationHover: \(target.tableID, privacy: .public).\(target.columnName, privacy: .public) kind=\(String(describing: target.endpointKind), privacy: .public) isHovered=\(isHovered, privacy: .public) showAllCards=\(session.showAllGraphTableCards, privacy: .public) maximized=\(String(describing: session.maximizedPaneSide), privacy: .public)")

        if isHovered {
            clearRelationHoverTasks[source]?.cancel()
            clearRelationHoverTasks[source] = nil
            activeRelationHoverTargets[source] = target
            hoveredRelationTarget = target
            layoutRevision &+= 1
        } else {
            // Hover ended — delay the clear slightly so a re-render doesn't flicker it away
            clearRelationHoverTasks[source]?.cancel()
            clearRelationHoverTasks[source] = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                if activeRelationHoverTargets[source] == target {
                    activeRelationHoverTargets.removeValue(forKey: source)
                    hoveredRelationTarget = preferredRelationHoverTarget()
                    layoutRevision &+= 1
                }
                clearRelationHoverTasks[source] = nil
            }
        }
    }

    private func preferredRelationHoverTarget() -> GraphRelationHoverTarget? {
        activeRelationHoverTargets
            .sorted { lhs, rhs in
                if lhs.key.priority != rhs.key.priority {
                    return lhs.key.priority > rhs.key.priority
                }
                return lhs.key.stableSortKey < rhs.key.stableSortKey
            }
            .first?
            .value
    }

    private func clearRelationHoverState() {
        for task in clearRelationHoverTasks.values {
            task.cancel()
        }
        clearRelationHoverTasks.removeAll()
        activeRelationHoverTargets.removeAll()
        hoveredRelationTarget = nil
    }

    // MARK: - Viewport pull for off-screen related nodes

    /// Temporarily moves off-screen connected nodes adjacent to the source node within the
    /// current viewport. The viewport itself never changes; source node never leaves the screen.
    private func pullConnectedNodesIntoView(for target: GraphRelationHoverTarget) {
        guard draggedNodeID == nil else { return }

        let connectedIDs = relatedNodeIDs(for: target)
        guard !connectedIDs.isEmpty else { return }

        let transform = GraphViewportTransform(zoom: zoom, pan: pan)
        let viewport = CGRect(origin: .zero, size: viewportSize)

        let offScreenIDs = connectedIDs.filter { id in
            let center = transform.point(for: session.graphLayout.position(for: id), in: viewportSize)
            return !viewport.contains(center)
        }
        guard !offScreenIDs.isEmpty else {
            if !pulledGraphPositions.isEmpty {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { pulledGraphPositions.removeAll() }
                tappedRelationTarget = nil
            }
            return
        }

        let sourceGraphPos = session.graphLayout.position(for: target.tableID)
        let sourceScreenCenter = transform.point(for: sourceGraphPos, in: viewportSize)
        let sourceSize = nodeSize(for: target.tableID)
        let sourceHalfW = sourceSize.width * zoom / 2
        let sourceHalfH = sourceSize.height * zoom / 2

        // Screen-space gap between source card edge and each connected card edge.
        let gap: CGFloat = 70
        // Minimum screen-space gap to enforce between adjacent pulled cards in the ring.
        let interCardGap: CGFloat = 30
        let n = offScreenIDs.count

        // Compute the minimum ring radius that prevents adjacent cards from overlapping.
        // For N cards on a circle of radius R, the chord between neighbours = 2R·sin(π/N).
        // Use max(halfW, halfH) so tall expanded cards don't overlap vertically either.
        let maxConnectedHalfExtent = offScreenIDs.map { id -> CGFloat in
            let sz = nodeSize(for: id)
            return max(sz.width, sz.height) * zoom / 2
        }.max() ?? 0
        let minRadiusForSpacing: CGFloat = n > 1
            ? (maxConnectedHalfExtent + interCardGap / 2) / sin(.pi / CGFloat(n))
            : 0

        var newPositions: [String: CGPoint] = [:]

        for (index, connectedID) in offScreenIDs.enumerated() {
            // Evenly distribute angles starting from east (right), going counter-clockwise.
            let angle = (2.0 * .pi * CGFloat(index)) / CGFloat(n)
            let cosA = cos(angle)
            let sinA = sin(angle)

            let connectedSize = nodeSize(for: connectedID)
            let connectedHalfW = connectedSize.width * zoom / 2
            let connectedHalfH = connectedSize.height * zoom / 2

            // Bounding-box support in the radial direction (halfW·|cos|+halfH·|sin|).
            let srcExtent = sourceHalfW * abs(cosA) + sourceHalfH * abs(sinA)
            let dstExtent = connectedHalfW * abs(cosA) + connectedHalfH * abs(sinA)
            // Use whichever radius is larger: natural gap from source, or ring-spacing requirement.
            let naturalRadius = srcExtent + gap + dstExtent
            let radius = max(naturalRadius, minRadiusForSpacing)

            let candidateX = sourceScreenCenter.x + radius * cosA
            let candidateY = sourceScreenCenter.y + radius * sinA

            // Clamp to viewport so the pulled card is fully on screen.
            let clampedX = min(max(connectedHalfW + 8, candidateX), viewportSize.width  - connectedHalfW - 8)
            let clampedY = min(max(connectedHalfH + 8, candidateY), viewportSize.height - connectedHalfH - 8)

            newPositions[connectedID] = transform.graphPoint(for: CGPoint(x: clampedX, y: clampedY), in: viewportSize)
        }

        tappedRelationTarget = GraphRelationHoverTarget(
            tableID: target.tableID,
            columnName: target.columnName,
            endpointKind: .column
        )
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            pulledGraphPositions = newPositions
        }
    }

    private func relatedNodeIDs(for target: GraphRelationHoverTarget) -> [String] {
        session.graph.edges.compactMap { edge in
            if edge.sourceID == target.tableID && edge.sourceColumn == target.columnName {
                return edge.targetID == target.tableID ? nil : edge.targetID
            }
            if edge.targetID == target.tableID && edge.targetColumn == target.columnName {
                return edge.sourceID == target.tableID ? nil : edge.sourceID
            }
            return nil
        }
    }

    private func toggleExpandedState(for nodeID: String, in size: CGSize) {
        withAnimation(.snappy(duration: 0.18)) {
            session.selectGraphNode(nodeID)
        }

        pendingExpansionNodeID = nil

        if manuallyExpandedNodeID == nodeID {
            collapseExpandedNode(nodeID, in: size)
            return
        }

        if let manuallyExpandedNodeID {
            pendingExpansionNodeID = nodeID
            collapseExpandedNode(manuallyExpandedNodeID, in: size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard pendingExpansionNodeID == nodeID else { return }
                pendingExpansionNodeID = nil
                openExpandedNode(nodeID, in: size)
            }
            return
        }

        openExpandedNode(nodeID, in: size)
    }

    private func openExpandedNode(_ nodeID: String, in size: CGSize) {
        viewportRestorePoint = GraphViewportTransform(zoom: zoom, pan: pan)
        viewportRestoreNodeID = nodeID
        session.setExpandedGraphNode(nodeID)
        // Don't stabilize - just update layout revision to reflect size changes
        layoutRevision &+= 1
        focusExpandedNode(nodeID, in: size)
    }

    private func collapseExpandedNode(_ nodeID: String, in size: CGSize) {
        session.setExpandedGraphNode(nil)
        cardScrollOffsets.removeValue(forKey: nodeID)
        // Don't stabilize - just update layout revision to reflect size changes
        layoutRevision &+= 1
        restoreViewport(from: nodeID)
    }

    private func focusExpandedNode(_ nodeID: String, in size: CGSize) {
        guard let graphFrame = detailBounds(for: nodeID) else { return }
        let transform = GraphViewportTransform.focus(
            contentBounds: graphFrame.insetBy(dx: -28, dy: -28),
            in: size,
            currentZoom: zoom
        )
        setViewport(transform, animated: true)
    }

    private func restoreViewport(from nodeID: String) {
        guard viewportRestoreNodeID == nodeID, let viewportRestorePoint else { return }
        setViewport(viewportRestorePoint, animated: true)
        self.viewportRestorePoint = nil
        viewportRestoreNodeID = nil
    }

    private func detailBounds(for nodeID: String) -> CGRect? {
        guard var bounds = graphFrame(for: nodeID) else { return nil }
        for relatedNodeID in relatedPreviewByNode.keys {
            guard let frame = graphFrame(for: relatedNodeID) else { continue }
            bounds = bounds.union(frame)
        }
        return bounds
    }

    private func graphFrame(for nodeID: String) -> CGRect? {
        guard session.graph.nodes.contains(where: { $0.id == nodeID }) else { return nil }
        let size = nodeSize(for: nodeID)
        let center = session.graphLayout.position(for: nodeID)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func setViewport(_ transform: GraphViewportTransform, animated: Bool) {
        let updates = {
            zoom = transform.zoom
            baseZoom = transform.zoom
            pan = transform.pan
            panStart = transform.pan
        }

        if animated {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func applyTrackpadPan(_ delta: CGSize) {
        if let targetID = scrollTargetCardID {
            let totalColumns = session.descriptor(named: targetID)?.columns.count ?? 0
            if totalColumns > GraphCardLayout.maxExpandedVisibleRows {
                let maxOffset = CGFloat(totalColumns - GraphCardLayout.maxExpandedVisibleRows) * GraphCardLayout.expandedRowHeight
                let current = cardScrollOffsets[targetID] ?? 0
                // delta.height from scrollWheel: negative = fingers moving up = scroll content up = offset increases.
                let newOffset = max(0, min(maxOffset, current - delta.height / zoom))
                cardScrollOffsets[targetID] = newOffset
                return
            }
        }
        // IMPORTANT: Natural scrolling - moving fingers right pans viewport right (like moving the canvas)
        // DO NOT change the + signs to - signs - this has been intentionally set for natural scrolling
        pan = CGSize(
            width: pan.width + delta.width,
            height: pan.height + delta.height
        )
        panStart = pan
    }

    private func applyTrackpadMagnification(_ magnification: CGFloat, anchor: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let oldZoom = max(zoom, 0.01)
        let newZoom = max(0.12, min(oldZoom * (1 + magnification), 2.4))
        guard abs(newZoom - oldZoom) > 0.0001 else { return }

        let centeredAnchor = CGPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y - size.height / 2
        )
        let anchorGraphPoint = CGPoint(
            x: (centeredAnchor.x - pan.width) / oldZoom,
            y: (centeredAnchor.y - pan.height) / oldZoom
        )

        let nextPan = CGSize(
            width: centeredAnchor.x - anchorGraphPoint.x * newZoom,
            height: centeredAnchor.y - anchorGraphPoint.y * newZoom
        )

        zoom = newZoom
        baseZoom = newZoom
        pan = nextPan
        panStart = nextPan
    }
}

private struct FeaturesMenuButton: View {
    @Binding var isOpen: Bool
    @Binding var showCardinals: Bool
    @Binding var showClusterHalos: Bool
    let hasClusters: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            featuresCard
                .frame(width: isOpen ? nil : 0)
                .clipped()
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
                .animation(.snappy(duration: 0.18), value: isOpen)

            buttonLabel
        }
    }

    private var buttonLabel: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                isOpen.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .animation(.snappy(duration: 0.22), value: isOpen)
                Text("Features")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(StudioPalette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(isOpen ? StudioPalette.chromeFillStrong : StudioPalette.chromeFill))
            .overlay { Capsule().stroke(StudioPalette.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private var featuresCard: some View {
        HStack(spacing: 6) {
            Button {
                showCardinals.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showCardinals ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(showCardinals ? StudioPalette.accent : StudioPalette.secondaryText)
                    Text("Cardinals")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StudioPalette.primaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .fixedSize()
            }
            .buttonStyle(.plain)

            if hasClusters {
                Button {
                    showClusterHalos.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showClusterHalos ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                showClusterHalos ? StudioPalette.accent : StudioPalette.secondaryText
                            )
                        Text("Cluster Vis")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(StudioPalette.primaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Show or hide the colored backgrounds behind each cluster.")
            }
        }
        .background(.clear)
    }
}


private struct GraphNodeCardView<HeaderGesture: Gesture>: View {
    let node: GraphNode
    let descriptor: EditableTableDescriptor?
    let tableDescription: String?
    let clusterLabel: String?
    let columnDescription: (String) -> String?
    let previewColumns: [TableColumn]
    let outgoingEdges: [GraphEdge]
    let incomingEdges: [GraphEdge]
    let isSelected: Bool
    let displayStyle: GraphNodeCardStyle
    let scrollOffset: CGFloat
    let isHovered: Bool
    let isDragging: Bool
    let highlightState: GraphNodeHighlightState
    let selectNode: () -> Void
    let toggleExpanded: () -> Void
    let openTable: () -> Void
    let showTopRows: () -> Void
    let usesViewportHoverTracking: Bool
    let hoverChanged: (Bool) -> Void
    let relationHoverChanged: (GraphRelationHoverTarget, GraphRelationHoverSource, Bool) -> Void
    let relationTapped: (GraphRelationHoverTarget) -> Void
    let headerDragGesture: HeaderGesture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsDetailRows {
                Rectangle()
                    .fill(StudioPalette.divider)
                    .frame(height: 1)

                columnBody
                    .padding(.horizontal, GraphCardLayout.horizontalInset)
                    .padding(.top, bodyTopPadding)
                    .padding(.bottom, bodyBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundShape.fill(backgroundFill))
        .clipShape(backgroundShape)
        .overlay {
            backgroundShape
                .strokeBorder(borderColor, lineWidth: isSelected || isHovered ? 1.5 : 1.0)
        }
        .scaleEffect(isDragging ? 1.012 : (isHovered ? 1.004 : 1))
        .contentShape(backgroundShape)
        .onTapGesture {
            selectNode()
        }
        .onTapGesture(count: 2) {
            openTable()
        }
        .onHover { isHovered in
            guard !usesViewportHoverTracking else { return }
            hoverChanged(isHovered)
        }
        .contextMenu {
            Button(isExpanded ? "Collapse Card" : "Expand Card", action: toggleExpanded)
            Button("Open Table", action: openTable)
            Button("Show Top 10", action: showTopRows)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: displayStyle)
    }

    private var header: some View {
        HStack(spacing: 8) {
            let hasDescription = tableDescription != nil || clusterLabel != nil
            Text(node.title)
                .font(.system(size: showsDetailRows ? 13 : 12, weight: .semibold))
                .foregroundStyle(StudioPalette.primaryText)
                .underline(hasDescription, color: StudioPalette.primaryText.opacity(0.4))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            Text(fieldCountLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StudioPalette.headerSurface, in: Capsule())

            if let rowCountLabel {
                Text(rowCountLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioPalette.headerSurface.opacity(0.74), in: Capsule())
            }

            if isHovered || showsDetailRows {
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(StudioPalette.headerSurface.opacity(0.82))
                        )
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse card" : "Expand card")
            }
        }
        .padding(.horizontal, GraphCardLayout.horizontalInset)
        .frame(height: headerHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(headerDragGesture)
    }

    private func row(for column: TableColumn) -> some View {
        let isPrimaryKey = column.primaryKeyOrdinal > 0
        let isForeignKey = outgoingEdges.contains(where: { $0.sourceColumn == column.name })
        let isReferenced = incomingEdges.contains(where: { $0.targetColumn == column.name })
        let relationStyle: GraphNodeColumnHighlightStyle = highlightState.style(for: column.name)
        let columnNote = columnDescription(column.name)

        // Row hover follows every relationship for the column; badge hover below can still
        // narrow this to the PK/REF or FK side when a mixed key column needs disambiguation.
        let rowHoverTarget: GraphRelationHoverTarget? = {
            if isForeignKey || isReferenced {
                return GraphRelationHoverTarget(tableID: node.id, columnName: column.name, endpointKind: .column)
            }
            return nil
        }()
        let rowHoverSource = GraphRelationHoverSource(tableID: node.id, columnName: column.name, area: .row)

        return HStack(spacing: 8) {
            Text(column.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioPalette.primaryText)
                .underline(columnNote != nil, color: StudioPalette.primaryText.opacity(0.4))
            Spacer(minLength: 8)
            Text(column.typeLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioPalette.secondaryText)
            if isPrimaryKey {
                graphBadge(
                    "PK",
                    tint: StudioPalette.primaryKeyTint,
                    emphasis: relationStyle == .primary || relationStyle == .both,
                    hoverTarget: GraphRelationHoverTarget(tableID: node.id, columnName: column.name, endpointKind: .primary)
                )
            }
            if isForeignKey {
                graphBadge(
                    "FK",
                    tint: StudioPalette.foreignKeyTint,
                    emphasis: relationStyle == .foreign || relationStyle == .both,
                    hoverTarget: GraphRelationHoverTarget(tableID: node.id, columnName: column.name, endpointKind: .foreign)
                )
            }
            if isReferenced {
                graphBadge(
                    "REF",
                    tint: StudioPalette.referenceTint,
                    emphasis: relationStyle == .primary || relationStyle == .both,
                    hoverTarget: GraphRelationHoverTarget(tableID: node.id, columnName: column.name, endpointKind: .primary)
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: GraphCardLayout.expandedRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHighlightFill(for: relationStyle))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let rowHoverTarget {
                relationTapped(rowHoverTarget)   // pull only; card tap won't fire (tap consumed)
            } else {
                selectNode()                     // restore + select
            }
        }
        .onHover { isHovered in
            if let rowHoverTarget {
                relationHoverChanged(rowHoverTarget, rowHoverSource, isHovered)
            }
        }
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: showsDetailRows ? 22 : 18, style: .continuous)
    }

    private var fieldCountLabel: String {
        let fieldCount = descriptor?.columns.count ?? 0
        return fieldCount == 1 ? "1 field" : "\(fieldCount) fields"
    }

    private var rowCountLabel: String? {
        guard let rowCount = descriptor?.rowCount else { return nil }
        return rowCount == 1 ? "1 row" : "\(compactRowCount(rowCount)) rows"
    }

    private func compactRowCount(_ count: Int) -> String {
        switch count {
        case 0..<1_000:
            return "\(count)"
        case 1_000..<10_000:
            let k = Double(count) / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
        case 10_000..<1_000_000:
            return "\(count / 1_000)K"
        case 1_000_000..<10_000_000:
            let m = Double(count) / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
        case 10_000_000..<1_000_000_000:
            return "\(count / 1_000_000)M"
        case 1_000_000_000..<10_000_000_000:
            let b = Double(count) / 1_000_000_000
            return b.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(b))B" : String(format: "%.1fB", b)
        default:
            return "\(count / 1_000_000_000)B"
        }
    }

    private var backgroundFill: some ShapeStyle {
        LinearGradient(
            colors: isSelected
                ? [
                    StudioPalette.selectionSurfaceTop,
                    StudioPalette.selectionSurfaceBottom,
                ]
                : [
                    StudioPalette.cardSurfaceTop,
                    StudioPalette.cardSurfaceBottom,
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var borderColor: Color {
        if isHovered                { return Color.black.opacity(0.26) }
        if highlightState != .empty { return Color.black.opacity(0.22) }
        if isSelected               { return Color.black.opacity(0.20) }
        return Color.black.opacity(0.11)
    }

    private func graphBadge(_ title: String, tint: Color, emphasis: Bool, hoverTarget: GraphRelationHoverTarget) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint.opacity(emphasis ? 0.98 : 0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(tint.opacity(emphasis ? 0.18 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(tint.opacity(emphasis ? 0.32 : 0.18), lineWidth: 1)
            }
            .onTapGesture {
                relationTapped(hoverTarget)     // pull only; badge tap consumed, card tap won't fire
            }
            .onHover { isHovered in
                StudioLog.graph.debug("badge.onHover: \(hoverTarget.tableID, privacy: .public).\(hoverTarget.columnName, privacy: .public) isHovered=\(isHovered, privacy: .public)")
                let source = GraphRelationHoverSource(
                    tableID: hoverTarget.tableID,
                    columnName: hoverTarget.columnName,
                    area: .badge(hoverTarget.endpointKind)
                )
                relationHoverChanged(hoverTarget, source, isHovered)
            }
    }

    private func rowHighlightFill(for style: GraphNodeColumnHighlightStyle) -> Color {
        switch style {
        case .none:
            return .clear
        case .primary:
            return StudioPalette.primaryKeyTint.opacity(0.08)
        case .foreign:
            return StudioPalette.foreignKeyTint.opacity(0.08)
        case .both:
            return Color(red: 0.68, green: 0.66, blue: 0.62).opacity(0.14)
        }
    }

    private var displayedColumns: [TableColumn] {
        switch displayStyle {
        case .collapsed:
            return []
        case .preview:
            return previewColumns
        case .expanded:
            let allColumns = descriptor?.columns ?? []
            let total = allColumns.count
            if total <= GraphCardLayout.maxExpandedVisibleRows { return allColumns }
            // Show maxRows + 1 for smooth fractional scroll (partial bottom row when mid-row).
            let scrollIndex = Int(scrollOffset / GraphCardLayout.expandedRowHeight)
            let endIndex = min(scrollIndex + GraphCardLayout.maxExpandedVisibleRows + 1, total)
            return Array(allColumns[scrollIndex..<endIndex])
        }
    }

    private var scrollFractionalOffset: CGFloat {
        guard isExpanded else { return 0 }
        let total = descriptor?.columns.count ?? 0
        guard total > GraphCardLayout.maxExpandedVisibleRows else { return 0 }
        return scrollOffset.truncatingRemainder(dividingBy: GraphCardLayout.expandedRowHeight)
    }

    @ViewBuilder private var columnBody: some View {
        let isScrollableExpanded = isExpanded && (descriptor?.columns.count ?? 0) > GraphCardLayout.maxExpandedVisibleRows
        if isScrollableExpanded {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayedColumns) { column in
                    row(for: column)
                }
            }
            .offset(y: -scrollFractionalOffset)
            .frame(height: CGFloat(GraphCardLayout.maxExpandedVisibleRows) * GraphCardLayout.expandedRowHeight, alignment: .top)
            .clipped()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayedColumns) { column in
                    row(for: column)
                }
            }
        }
    }

    private var showsDetailRows: Bool {
        switch displayStyle {
        case .collapsed:
            return false
        case .preview, .expanded:
            return true
        }
    }

    private var isExpanded: Bool {
        if case .expanded = displayStyle {
            return true
        }
        return false
    }

    private var headerHeight: CGFloat {
        switch displayStyle {
        case .collapsed:
            return GraphCardLayout.collapsedHeight
        case .preview:
            return GraphCardLayout.previewHeaderHeight
        case .expanded:
            return GraphCardLayout.expandedHeaderHeight
        }
    }

    private var bodyTopPadding: CGFloat {
        switch displayStyle {
        case .preview:
            return GraphCardLayout.previewBodyTopPadding
        case .collapsed, .expanded:
            return GraphCardLayout.expandedBodyTopPadding
        }
    }

    private var bodyBottomPadding: CGFloat {
        switch displayStyle {
        case .preview:
            return GraphCardLayout.previewVerticalPadding
        case .collapsed, .expanded:
            return GraphCardLayout.expandedVerticalPadding
        }
    }
}

struct GraphRelationHighlight {
    let focusNodeID: String?
    let hoverTarget: GraphRelationHoverTarget?
    let highlightedEdgeIDs: Set<String>
    let foreignKeyColumnsByTable: [String: Set<String>]
    let primaryKeyColumnsByTable: [String: Set<String>]

    init(graph: SchemaGraph, focusNodeID: String?, hoverTarget: GraphRelationHoverTarget? = nil) {
        self.focusNodeID = focusNodeID
        self.hoverTarget = hoverTarget

        if let hoverTarget {
            let highlightedEdges = graph.edges.filter { edge in
                switch hoverTarget.endpointKind {
                case .column:
                    return (edge.sourceID == hoverTarget.tableID && edge.sourceColumn == hoverTarget.columnName)
                        || (edge.targetID == hoverTarget.tableID && edge.targetColumn == hoverTarget.columnName)
                case .primary:
                    return edge.targetID == hoverTarget.tableID && edge.targetColumn == hoverTarget.columnName
                case .foreign:
                    return edge.sourceID == hoverTarget.tableID && edge.sourceColumn == hoverTarget.columnName
                }
            }

            var foreignKeyColumnsByTable: [String: Set<String>] = [:]
            var primaryKeyColumnsByTable: [String: Set<String>] = [:]
            for edge in highlightedEdges {
                foreignKeyColumnsByTable[edge.sourceID, default: []].insert(edge.sourceColumn)
                primaryKeyColumnsByTable[edge.targetID, default: []].insert(edge.targetColumn)
            }

            self.highlightedEdgeIDs = Set(highlightedEdges.map(\.id))
            self.foreignKeyColumnsByTable = foreignKeyColumnsByTable
            self.primaryKeyColumnsByTable = primaryKeyColumnsByTable
            return
        }

        guard let focusNodeID else {
            self.highlightedEdgeIDs = []
            self.foreignKeyColumnsByTable = [:]
            self.primaryKeyColumnsByTable = [:]
            return
        }

        var highlightedEdgeIDs: Set<String> = []

        for edge in graph.edges where edge.sourceID == focusNodeID || edge.targetID == focusNodeID {
            highlightedEdgeIDs.insert(edge.id)
        }

        self.highlightedEdgeIDs = highlightedEdgeIDs
        self.foreignKeyColumnsByTable = [:]
        self.primaryKeyColumnsByTable = [:]
    }

    func highlightState(for tableID: String) -> GraphNodeHighlightState {
        GraphNodeHighlightState(
            primaryKeyColumns: primaryKeyColumnsByTable[tableID, default: []],
            foreignKeyColumns: foreignKeyColumnsByTable[tableID, default: []]
        )
    }
}

struct DescriptionHover: Equatable {
    let nodeID: String
    let column: String?  // nil = table-level description
    let text: String
}

struct GraphRelationHoverTarget: Sendable, Hashable {
    let tableID: String
    let columnName: String
    let endpointKind: GraphRelationEndpointKind
}

enum GraphRelationEndpointKind: Sendable, Hashable {
    case column
    case primary
    case foreign
}

private struct GraphNodeRelationPreview {
    var foreignKeyColumns: Set<String> = []
    var primaryKeyColumns: Set<String> = []

    static let empty = GraphNodeRelationPreview()
}

private struct GraphEdgeLookup {
    private let outgoingEdgesByTable: [String: [GraphEdge]]
    private let incomingEdgesByTable: [String: [GraphEdge]]

    init(edges: [GraphEdge]) {
        outgoingEdgesByTable = Dictionary(grouping: edges, by: \.sourceID)
            .mapValues(Self.sortedOutgoingEdges)
        incomingEdgesByTable = Dictionary(grouping: edges, by: \.targetID)
            .mapValues(Self.sortedIncomingEdges)
    }

    func outgoingEdges(for tableID: String) -> [GraphEdge] {
        outgoingEdgesByTable[tableID, default: []]
    }

    func incomingEdges(for tableID: String) -> [GraphEdge] {
        incomingEdgesByTable[tableID, default: []]
    }

    private static func sortedOutgoingEdges(_ edges: [GraphEdge]) -> [GraphEdge] {
        edges.sorted { lhs, rhs in
            if lhs.sourceColumn == rhs.sourceColumn {
                return lhs.targetID.localizedStandardCompare(rhs.targetID) == .orderedAscending
            }
            return lhs.sourceColumn.localizedStandardCompare(rhs.sourceColumn) == .orderedAscending
        }
    }

    private static func sortedIncomingEdges(_ edges: [GraphEdge]) -> [GraphEdge] {
        edges.sorted { lhs, rhs in
            if lhs.sourceID == rhs.sourceID {
                return lhs.sourceColumn.localizedStandardCompare(rhs.sourceColumn) == .orderedAscending
            }
            return lhs.sourceID.localizedStandardCompare(rhs.sourceID) == .orderedAscending
        }
    }
}

struct GraphRelationHoverSource: Sendable, Hashable {
    let tableID: String
    let columnName: String
    let area: GraphRelationHoverArea

    var priority: Int {
        area.priority
    }

    var stableSortKey: String {
        "\(tableID)|\(columnName)|\(area.stableSortKey)"
    }
}

enum GraphRelationHoverArea: Sendable, Hashable {
    case row
    case badge(GraphRelationEndpointKind)

    var priority: Int {
        switch self {
        case .badge:
            return 2
        case .row:
            return 1
        }
    }

    var stableSortKey: String {
        switch self {
        case .row:
            return "row"
        case .badge(let endpointKind):
            return "badge-\(endpointKind)"
        }
    }
}

struct GraphNodeHighlightState: Equatable {
    let primaryKeyColumns: Set<String>
    let foreignKeyColumns: Set<String>

    static let empty = GraphNodeHighlightState(primaryKeyColumns: [], foreignKeyColumns: [])

    func style(for columnName: String) -> GraphNodeColumnHighlightStyle {
        let isPrimary = primaryKeyColumns.contains(columnName)
        let isForeign = foreignKeyColumns.contains(columnName)

        switch (isPrimary, isForeign) {
        case (false, false):
            return .none
        case (true, false):
            return .primary
        case (false, true):
            return .foreign
        case (true, true):
            return .both
        }
    }
}

enum GraphNodeColumnHighlightStyle: Equatable {
    case none
    case primary
    case foreign
    case both
}


private struct GraphTrackpadInputSurface: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void
    let onPointerMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> GraphTrackpadInputView {
        let view = GraphTrackpadInputView()
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.onPointerMove = onPointerMove
        return view
    }

    func updateNSView(_ nsView: GraphTrackpadInputView, context: Context) {
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
        nsView.onPointerMove = onPointerMove
        nsView.refreshTrackingState()
    }
}

@MainActor
private final class GraphTrackpadInputView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onPointerMove: ((CGPoint?) -> Void)?

    private nonisolated(unsafe) var eventMonitor: Any?
    private var trackingAreaReference: NSTrackingArea?
    private var lastPublishedPointerPoint: CGPoint?
    private var isPointerInside = false

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refreshTrackingState()
        installMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            publishPointerMove(nil)
            removeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTrackingState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        publishPointerMove(pointInBounds(for: event))
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        publishPointerMove(pointInBounds(for: event))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        publishPointerMove(nil)
        super.mouseExited(with: event)
    }

    func refreshTrackingState() {
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        refreshPointerFromWindowLocation(force: true)
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
            guard self.window != nil else {
                if event.type == .mouseMoved {
                    StudioLog.graph.debug("trackpad.mouseMoved: window is nil, skipping")
                }
                return event
            }
            let point = self.convert(event.locationInWindow, from: nil)
            let isInside = self.bounds.contains(point)

            switch event.type {
            case .scrollWheel:
                guard event.window === self.window else { return event }
                guard isInside else { return event }
                guard event.hasPreciseScrollingDeltas else { return event }
                self.onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil
            case .magnify:
                guard event.window === self.window else { return event }
                guard isInside else { return event }
                self.onMagnify?(event.magnification, point)
                return nil
            case .mouseMoved:
                let inside = self.bounds.contains(point)
                let frameInWindow = self.convert(self.bounds, to: nil)
                StudioLog.graph.debug("trackpad.mouseMoved point=\(point.x, privacy: .public),\(point.y, privacy: .public) bounds=\(self.bounds.width, privacy: .public)x\(self.bounds.height, privacy: .public) frameInWindow=\(frameInWindow.origin.x, privacy: .public),\(frameInWindow.origin.y, privacy: .public) inside=\(inside, privacy: .public)")
                self.publishPointerMove(inside ? point : nil)
                return event
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func refreshPointerFromWindowLocation(force: Bool = false) {
        guard let window else {
            publishPointerMove(nil, force: force)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        publishPointerMove(bounds.contains(point) ? point : nil, force: force)
    }

    private func pointInBounds(for event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) ? point : nil
    }

    private func publishPointerMove(_ point: CGPoint?, force: Bool = false) {
        guard force || point != lastPublishedPointerPoint || (point != nil) != isPointerInside else { return }
        lastPublishedPointerPoint = point
        isPointerInside = point != nil
        onPointerMove?(point)
    }
}

struct GraphMinimapView: View {
    @Bindable var session: AppSession
    let viewportSize: CGSize
    let zoom: CGFloat
    let pan: CGSize
    let onViewportTap: (CGPoint) -> Void
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioPalette.chromeFill.opacity(0.95))
            
            // Graph content
            Canvas { context, size in
                let contentBounds = graphContentBounds()
                guard !contentBounds.isEmpty else { return }
                
                let minimapTransform = calculateMinimapTransform(contentBounds: contentBounds, minimapSize: size)
                
                // Draw edges first (behind nodes)
                for edge in session.graph.edges {
                    let sourcePos = session.graphLayout.position(for: edge.sourceID)
                    let targetPos = session.graphLayout.position(for: edge.targetID)
                    let minimapSource = minimapTransform.point(for: sourcePos, in: size)
                    let minimapTarget = minimapTransform.point(for: targetPos, in: size)
                    
                    var path = Path()
                    path.move(to: minimapSource)
                    path.addLine(to: minimapTarget)
                    context.stroke(
                        path,
                        with: .color(StudioPalette.edgeNeutral.opacity(0.3)),
                        lineWidth: 0.5
                    )
                }
                
                // Draw nodes
                for node in session.graph.nodes {
                    let nodePos = session.graphLayout.position(for: node.id)
                    let minimapPos = minimapTransform.point(for: nodePos, in: size)
                    let nodeRect = CGRect(
                        x: minimapPos.x - 2,
                        y: minimapPos.y - 2,
                        width: 4,
                        height: 4
                    )
                    context.fill(
                        Path(roundedRect: nodeRect, cornerRadius: 1),
                        with: .color(StudioPalette.primaryText.opacity(0.6))
                    )
                }
                
                // Draw viewport indicator
                let viewportRect = calculateViewportRect(
                    contentBounds: contentBounds,
                    minimapSize: size,
                    minimapTransform: minimapTransform
                )
                context.stroke(
                    Path(roundedRect: viewportRect, cornerRadius: 2),
                    with: .color(StudioPalette.accent),
                    lineWidth: 1.5
                )
                context.fill(
                    Path(roundedRect: viewportRect, cornerRadius: 2),
                    with: .color(StudioPalette.accent.opacity(0.15))
                )
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                onViewportTap(location)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioPalette.border, lineWidth: 1)
        }
        .shadow(color: StudioPalette.shadow.opacity(0.5), radius: 12, y: 8)
    }
    
    private func graphContentBounds() -> CGRect {
        guard !session.graph.nodes.isEmpty else { return .zero }
        
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        
        for node in session.graph.nodes {
            let pos = session.graphLayout.position(for: node.id)
            minX = min(minX, pos.x)
            minY = min(minY, pos.y)
            maxX = max(maxX, pos.x)
            maxY = max(maxY, pos.y)
        }
        
        let padding: CGFloat = 100
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2
        )
    }
    
    private func calculateMinimapTransform(contentBounds: CGRect, minimapSize: CGSize) -> GraphViewportTransform {
        guard !contentBounds.isEmpty else { return .identity }
        
        let scaleX = minimapSize.width / contentBounds.width
        let scaleY = minimapSize.height / contentBounds.height
        let scale = min(scaleX, scaleY) * 0.9
        
        let centerX = contentBounds.midX
        let centerY = contentBounds.midY
        
        return GraphViewportTransform(
            zoom: scale,
            pan: CGSize(width: -centerX * scale, height: -centerY * scale)
        )
    }
    
    private func calculateViewportRect(
        contentBounds: CGRect,
        minimapSize: CGSize,
        minimapTransform: GraphViewportTransform
    ) -> CGRect {
        let currentTransform = GraphViewportTransform(zoom: zoom, pan: pan)
        
        // Calculate the four corners of the current viewport in graph space
        let topLeft = currentTransform.graphPoint(for: .zero, in: viewportSize)
        let bottomRight = currentTransform.graphPoint(
            for: CGPoint(x: viewportSize.width, y: viewportSize.height),
            in: viewportSize
        )
        
        // Transform to minimap space
        let minimapTopLeft = minimapTransform.point(for: topLeft, in: minimapSize)
        let minimapBottomRight = minimapTransform.point(for: bottomRight, in: minimapSize)
        
        return CGRect(
            x: minimapTopLeft.x,
            y: minimapTopLeft.y,
            width: minimapBottomRight.x - minimapTopLeft.x,
            height: minimapBottomRight.y - minimapTopLeft.y
        )
    }
}

/// Reference-type cache so Path.union is computed only when positions change,
/// not on every pan/zoom frame. Held via @State so SwiftUI owns the lifetime.
private final class HaloCache {
    struct Entry {
        let color: Color
        let path: Path  // graph-space coordinates
        let label: String?
    }
    var layoutRevision: Int = -1
    var entries: [Entry] = []
}

