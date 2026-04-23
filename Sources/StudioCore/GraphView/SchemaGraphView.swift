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
    @State private var draggedNodeID: String?
    @State private var hoveredNodeID: String?
    @State private var layoutRevision = 0
    @State private var pendingExpansionNodeID: String?
    @State private var selectionRectStart: CGPoint?
    @State private var selectionRectCurrent: CGPoint?
    @State private var isShiftPressed = false

    public init(session: AppSession) {
        self.session = session
    }

    private var presentationMode: GraphPresentationMode {
        session.showAllGraphTableCards ? .allCards : .compact
    }

    private var focusNodeID: String? {
        manuallyExpandedNodeID ?? hoveredNodeID ?? session.selectedGraphNodeID
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
                performInitialLayout(in: geometry.size)
                guard !hasPerformedSettledInitialLayout else { return }
                hasPerformedSettledInitialLayout = true
                DispatchQueue.main.async {
                    performInitialLayout(in: geometry.size)
                }
            }
            .onChange(of: geometry.size) { oldSize, newSize in
                viewportSize = newSize
                if !session.graph.nodes.isEmpty, oldSize == .zero, newSize != .zero {
                    fitGraph(in: newSize)
                }
            }
            .onChange(of: session.graph) { _, _ in
                performInitialLayout(in: geometry.size)
            }
            .onChange(of: session.showAllGraphTableCards) { _, isPresented in
                viewportRestorePoint = nil
                viewportRestoreNodeID = nil
                pendingExpansionNodeID = nil
                rebuildLayout(in: geometry.size, refit: isPresented, clearPinnedState: true, persistLayout: false)
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
        let relationHighlight = GraphRelationHighlight(graph: session.graph, focusNodeID: focusNodeID)
        let _ = layoutRevision

        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(backgroundPanGesture)

            GraphTrackpadInputSurface(
                onPan: { delta in
                    applyTrackpadPan(delta)
                },
                onMagnify: { magnification, anchor in
                    applyTrackpadMagnification(magnification, anchor: anchor, in: size)
                }
            )
            .allowsHitTesting(false)

            Canvas { context, _ in
                drawEdges(in: &context, anchorMap: anchorMap, relationHighlight: relationHighlight)
            }
            .allowsHitTesting(false)

            ForEach(session.graph.nodes) { node in
                let descriptor = session.descriptor(named: node.id)
                let outgoingEdges = session.outgoingEdges(for: node.id)
                let incomingEdges = session.incomingEdges(for: node.id)
                let previewColumns = previewColumns(for: node.id)
                let displayStyle = nodeDisplayStyle(for: node.id, previewColumns: previewColumns)
                let cardSize = nodeSize(for: node.id)

                GraphNodeCardView(
                    node: node,
                    descriptor: descriptor,
                    previewColumns: previewColumns,
                    outgoingEdges: outgoingEdges,
                    incomingEdges: incomingEdges,
                    isSelected: session.selectedGraphNodeIDs.contains(node.id),
                    displayStyle: displayStyle,
                    isHovered: hoveredNodeID == node.id,
                    isDragging: draggedNodeID == node.id,
                    highlightState: relationHighlight.highlightState(for: node.id),
                    selectNode: {
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
                    hoverChanged: { isHovered in
                        handleHoverChange(isHovered, for: node.id)
                    },
                    headerDragGesture: nodeDragGesture(nodeID: node.id, in: size)
                )
                .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
                .scaleEffect(zoom)
                .position(screenCenter(for: node.id, in: size))
                .shadow(
                    color: StudioPalette.shadow.opacity(draggedNodeID == node.id ? 1.0 : 0.8),
                    radius: draggedNodeID == node.id ? 26 : (session.selectedGraphNodeIDs.contains(node.id) ? 22 : 12),
                    y: draggedNodeID == node.id ? 16 : 10
                )
                .overlay {
                    // Multi-selection indicator
                    if session.selectedGraphNodeIDs.contains(node.id) && session.selectedGraphNodeIDs.count > 1 {
                        RoundedRectangle(cornerRadius: displayStyle == .collapsed ? 18 : 22, style: .continuous)
                            .stroke(StudioPalette.accent, lineWidth: 3)
                            .padding(-2)
                    }
                }
                .zIndex(zIndex(for: node.id))
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
        }
        .coordinateSpace(name: "graphViewport")
        .onTapGesture {
            // Deselect all nodes when clicking empty space
            session.clearGraphSelection()
        }
        .animation(.snappy(duration: 0.18), value: session.expandedGraphNodeIDs)
        .animation(.snappy(duration: 0.18), value: session.showAllGraphTableCards)
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
                : StudioPalette.edgeNeutral.opacity(session.showAllGraphTableCards ? 0.32 : 0.18)

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
                    lineWidth: isHighlighted ? 1.85 : (session.showAllGraphTableCards ? 1.15 : 0.9),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            
            // Draw directional arrow at the end (target side)
            if isHighlighted {
                drawArrowhead(in: &context, at: anchors.target, direction: edgeDirection(from: anchors.source, to: anchors.target), color: StudioPalette.edgeHighlight)
            }
        }
    }
    
    private func edgeDirection(from start: CGPoint, to end: CGPoint) -> CGFloat {
        return atan2(end.y - start.y, end.x - start.x)
    }
    
    private func drawArrowhead(in context: inout GraphicsContext, at point: CGPoint, direction: CGFloat, color: Color) {
        let arrowSize: CGFloat = 8
        let arrowAngle: CGFloat = .pi / 6  // 30 degrees
        
        // Calculate the two points of the arrowhead
        let point1 = CGPoint(
            x: point.x - arrowSize * cos(direction - arrowAngle),
            y: point.y - arrowSize * sin(direction - arrowAngle)
        )
        let point2 = CGPoint(
            x: point.x - arrowSize * cos(direction + arrowAngle),
            y: point.y - arrowSize * sin(direction + arrowAngle)
        )
        
        var arrowPath = Path()
        arrowPath.move(to: point1)
        arrowPath.addLine(to: point)
        arrowPath.addLine(to: point2)
        
        context.stroke(
            arrowPath,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    private func edgePath(from start: CGPoint, to end: CGPoint) -> Path {
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

        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    private func graphOverlayControls(size: CGSize) -> some View {
        ZStack {
            // Main controls (top right)
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        fitGraph(in: size)
                    } label: {
                        Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(StudioPalette.accent)

                    Button {
                        rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
                    } label: {
                        Label("Relayout", systemImage: "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(StudioPalette.accent)
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
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back to Content")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(StudioPalette.primaryText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    Capsule()
                        .fill(StudioPalette.chromeFill)
                )
                .overlay {
                    Capsule()
                        .stroke(StudioPalette.border, lineWidth: 1.5)
                }
                .shadow(color: StudioPalette.shadow.opacity(0.8), radius: 20, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            
            // Minimap (bottom right)
            GraphMinimapView(
                session: session,
                viewportSize: size,
                zoom: zoom,
                pan: pan,
                onViewportTap: { minimapPoint in
                    // Convert minimap tap to graph coordinates and pan there
                    let contentBounds = graphContentBounds()
                    let minimapSize = CGSize(width: 180, height: 120)
                    
                    // Calculate what graph point this minimap point represents
                    let scaleX = minimapSize.width / contentBounds.width
                    let scaleY = minimapSize.height / contentBounds.height
                    let scale = min(scaleX, scaleY) * 0.9
                    
                    let graphX = (minimapPoint.x - minimapSize.width / 2) / scale + contentBounds.midX
                    let graphY = (minimapPoint.y - minimapSize.height / 2) / scale + contentBounds.midY
                    
                    // Pan to center this point
                    let targetTransform = GraphViewportTransform(
                        zoom: zoom,
                        pan: CGSize(width: -graphX * zoom, height: -graphY * zoom)
                    )
                    setViewport(targetTransform, animated: true)
                }
            )
            .frame(width: 180, height: 120)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
    
    private func shouldShowBackToContent(in size: CGSize) -> Bool {
        guard !session.graph.nodes.isEmpty else { return false }
        
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
                    
                    // If node is not in selection, select only this node
                    if !session.selectedGraphNodeIDs.contains(nodeID) {
                        session.selectGraphNode(nodeID)
                    }
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
                        let originalPos = session.graphLayout.position(for: selectedNodeID)
                        let newPos = CGPoint(
                            x: originalPos.x + delta.x,
                            y: originalPos.y + delta.y
                        )
                        session.graphLayout.pin(nodeID: selectedNodeID, at: newPos)
                    }
                    nodeDragOrigin = moved
                } else {
                    session.graphLayout.pin(nodeID: nodeID, at: moved)
                }
                
                layoutRevision &+= 1
            }
            .onEnded { _ in
                draggedNodeID = nil
                nodeDragOrigin = nil
                nodeDragPointerOffset = nil
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
            return nil
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
        GraphViewportTransform(zoom: zoom, pan: pan)
            .point(for: session.graphLayout.position(for: nodeID), in: canvasSize)
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

    private func performInitialLayout(in size: CGSize) {
        guard !session.graph.nodes.isEmpty else { return }

        if session.graphLayout.hasRestoredSnapshot {
            stabilizeLayout(in: size, refit: true, persistLayout: false)
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
            maxIterations: presentationMode == .allCards ? 360 : 260
        )
        layoutRevision &+= 1

        if persistLayout, !session.showAllGraphTableCards {
            session.persistCurrentGraphLayout()
        }

        if refit {
            fitGraph(in: size)
        }
    }

    private func stabilizeLayout(in size: CGSize, refit: Bool, persistLayout: Bool) {
        session.graphLayout.stabilize(
            graph: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) },
            nodeSizeLookup: { nodeSize(for: $0) },
            maxIterations: presentationMode == .allCards ? 360 : 260
        )
        layoutRevision &+= 1

        if persistLayout, !session.showAllGraphTableCards {
            session.persistCurrentGraphLayout()
        }

        if refit {
            fitGraph(in: size)
        }
    }

    private func handleHoverChange(_ isHovered: Bool, for nodeID: String) {
        guard draggedNodeID == nil else { return }

        withAnimation(.snappy(duration: 0.16)) {
            if isHovered {
                hoveredNodeID = nodeID
            } else if hoveredNodeID == nodeID {
                hoveredNodeID = nil
            }
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
        let newZoom = max(0.42, min(oldZoom * (1 + magnification), 2.4))
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

private struct GraphNodeCardView<HeaderGesture: Gesture>: View {
    let node: GraphNode
    let descriptor: EditableTableDescriptor?
    let previewColumns: [TableColumn]
    let outgoingEdges: [GraphEdge]
    let incomingEdges: [GraphEdge]
    let isSelected: Bool
    let displayStyle: GraphNodeCardStyle
    let isHovered: Bool
    let isDragging: Bool
    let highlightState: GraphNodeHighlightState
    let selectNode: () -> Void
    let toggleExpanded: () -> Void
    let openTable: () -> Void
    let hoverChanged: (Bool) -> Void
    let headerDragGesture: HeaderGesture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsDetailRows {
                Rectangle()
                    .fill(StudioPalette.divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedColumns) { column in
                        row(for: column)
                    }
                }
                .padding(.horizontal, GraphCardLayout.horizontalInset)
                .padding(.top, bodyTopPadding)
                .padding(.bottom, bodyBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundShape.fill(backgroundFill))
        .overlay {
            backgroundShape
                .stroke(borderColor, lineWidth: isSelected || isHovered ? 1.4 : 1)
        }
        .scaleEffect(isDragging ? 1.012 : (isHovered ? 1.004 : 1))
        .contentShape(backgroundShape)
        .onTapGesture {
            selectNode()
        }
        .onTapGesture(count: 2) {
            openTable()
        }
        .onHover(perform: hoverChanged)
        .contextMenu {
            Button(isExpanded ? "Collapse Card" : "Expand Card", action: toggleExpanded)
            Button("Open Table", action: openTable)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: displayStyle)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(node.title)
                .font(.system(size: showsDetailRows ? 13 : 12, weight: .semibold))
                .foregroundStyle(StudioPalette.primaryText)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            Text(fieldCountLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StudioPalette.headerSurface, in: Capsule())

            if isHovered || showsDetailRows {
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(StudioPalette.headerSurface.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
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
        // Only highlight PK/FK when THIS node is hovered, not when related nodes are hovered
        let relationStyle: GraphNodeColumnHighlightStyle = isHovered ? highlightState.style(for: column.name) : .none

        return HStack(spacing: 8) {
            Text(column.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioPalette.primaryText)
            Spacer(minLength: 8)
            Text(column.typeLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioPalette.secondaryText)
            if isPrimaryKey {
                graphBadge(
                    "PK",
                    tint: StudioPalette.primaryKeyTint,
                    emphasis: relationStyle == .primary || relationStyle == .both
                )
            }
            if isForeignKey {
                graphBadge(
                    "FK",
                    tint: StudioPalette.foreignKeyTint,
                    emphasis: relationStyle == .foreign || relationStyle == .both
                )
            }
            if isReferenced {
                graphBadge(
                    "REF",
                    tint: StudioPalette.referenceTint,
                    emphasis: relationStyle == .primary || relationStyle == .both
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: GraphCardLayout.expandedRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHighlightFill(for: relationStyle))
        )
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: showsDetailRows ? 22 : 18, style: .continuous)
    }

    private var fieldCountLabel: String {
        let fieldCount = descriptor?.columns.count ?? 0
        return fieldCount == 1 ? "1 field" : "\(fieldCount) fields"
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
        if isHovered {
            return StudioPalette.borderStrong
        }
        if isSelected {
            return StudioPalette.border
        }
        return StudioPalette.borderSoft
    }

    private func graphBadge(_ title: String, tint: Color, emphasis: Bool) -> some View {
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
            return descriptor?.columns ?? []
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

private struct GraphRelationHighlight {
    let focusNodeID: String?
    let highlightedEdgeIDs: Set<String>
    let foreignKeyColumnsByTable: [String: Set<String>]
    let primaryKeyColumnsByTable: [String: Set<String>]

    init(graph: SchemaGraph, focusNodeID: String?) {
        self.focusNodeID = focusNodeID

        guard let focusNodeID else {
            self.highlightedEdgeIDs = []
            self.foreignKeyColumnsByTable = [:]
            self.primaryKeyColumnsByTable = [:]
            return
        }

        var highlightedEdgeIDs: Set<String> = []
        var foreignKeyColumnsByTable: [String: Set<String>] = [:]
        var primaryKeyColumnsByTable: [String: Set<String>] = [:]

        for edge in graph.edges where edge.sourceID == focusNodeID || edge.targetID == focusNodeID {
            highlightedEdgeIDs.insert(edge.id)
            primaryKeyColumnsByTable[edge.targetID, default: []].insert(edge.targetColumn)
            if edge.sourceID != focusNodeID {
                foreignKeyColumnsByTable[edge.sourceID, default: []].insert(edge.sourceColumn)
            }
        }

        self.highlightedEdgeIDs = highlightedEdgeIDs
        self.foreignKeyColumnsByTable = foreignKeyColumnsByTable
        self.primaryKeyColumnsByTable = primaryKeyColumnsByTable
    }

    func highlightState(for tableID: String) -> GraphNodeHighlightState {
        GraphNodeHighlightState(
            primaryKeyColumns: primaryKeyColumnsByTable[tableID, default: []],
            foreignKeyColumns: foreignKeyColumnsByTable[tableID, default: []]
        )
    }
}

private struct GraphNodeRelationPreview {
    var foreignKeyColumns: Set<String> = []
    var primaryKeyColumns: Set<String> = []

    static let empty = GraphNodeRelationPreview()
}

private struct GraphNodeHighlightState {
    let primaryKeyColumns: Set<String>
    let foreignKeyColumns: Set<String>

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

private enum GraphNodeColumnHighlightStyle {
    case none
    case primary
    case foreign
    case both
}


private struct GraphTrackpadInputSurface: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> GraphTrackpadInputView {
        let view = GraphTrackpadInputView()
        view.onPan = onPan
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ nsView: GraphTrackpadInputView, context: Context) {
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
    }
}

@MainActor
private final class GraphTrackpadInputView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?

    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.window != nil else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            switch event.type {
            case .scrollWheel:
                guard event.hasPreciseScrollingDeltas else { return event }
                self.onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil
            case .magnify:
                self.onMagnify?(event.magnification, point)
                return nil
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
}

private struct GraphMinimapView: View {
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
