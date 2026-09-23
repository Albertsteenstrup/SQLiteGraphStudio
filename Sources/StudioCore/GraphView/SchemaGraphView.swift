import AppKit
import SwiftUI

public struct SchemaGraphView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Bindable private var session: AppSession
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var initialViewport = GraphInitialViewport()
    @State private var initialViewportTask: Task<Void, Never>?
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
    @State private var clusterTitleCache = ClusterTitleCache()
    @State private var descriptionHover: DescriptionHover? = nil
    @State private var cardScrollOffsets: [String: CGFloat] = [:]
    @State private var scrollTargetCardID: String? = nil
    @State private var pulledGraphPositions: [String: CGPoint] = [:]
    @State private var tappedRelationTarget: GraphRelationHoverTarget? = nil
    @State private var graphFocusTableRelation: GraphRelationHoverTarget?
    @State private var tableFocusNodeID: String?
    @State private var graphControlsHeight: CGFloat = 48
    @State private var isGraphFilterPresented = false
    @State private var draggedNodeUsesFocusPull = false
    @State private var preGraphFocusViewport: GraphViewportBookmark?
    @State private var clusterTitleCacheKey: Int = 0
    @State private var isViewportPanning = false
    @State private var viewportPublisher = GraphInputPublisher<GraphViewportTransform>(interval: .milliseconds(32))
    @State private var isGraphNavigatorPresented = false
    @State private var focusedGroupID: String?
    @State private var focusedGroupPage = 0
    @State private var relationPageIndex = 0
    @State private var overviewViewport: GraphViewportBookmark?
    @State private var relationPreviewCache = RelationPreviewCache()
    @State private var topologyCache = GraphTopologyCache()
    @State private var interactionGeometryCache = GraphInteractionGeometryCache()
    @State private var scenePreparation = GraphScenePreparationCache()
    @State private var isGraphViewVisible = false

    /// Whether a graph decoration is switched on in View ▸ Graph Visuals.
    private func shows(_ visual: GraphVisual) -> Bool {
        session.graphVisuals.isEnabled(visual)
    }

    /// Relation signals redraw every frame, so on top of the reader's own preference they
    /// stop for anyone who asked the system to reduce motion and for windows the user has
    /// left — a background graph has no reader to inform and no reason to hold the display
    /// link awake.
    ///
    /// They also stay out of a schema review, which spends colour and symbols directing the
    /// eye to what changed; ambient motion there competes with the one thing being read.
    private var animatesRelationPulses: Bool {
        shows(.relationPulses) && session.schemaReview == nil
            && !reduceMotion && controlActiveState != .inactive
    }

    private var isLargeGraph: Bool { renderedGraph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold }
    private var usesOverviewMarks: Bool { (isLargeGraph || session.graphNodeSizeMetric != .uniform) && zoom < GraphExploration.detailZoom }

    public init(session: AppSession) {
        self.session = session
    }

    private var presentationMode: GraphPresentationMode {
        session.showAllGraphTableCards ? .allCards : .compact
    }

    private var renderedGraph: SchemaGraph {
        guard session.automationVisibleTableIDs != nil || session.graphTableFilter.isActive else {
            return session.graph
        }
        let visibleIDs = session.graphVisibleTableIDs
        let nodes = session.graph.nodes.filter { visibleIDs.contains($0.id) }
        let edges = session.graph.edges.filter {
            visibleIDs.contains($0.sourceID) && visibleIDs.contains($0.targetID)
        }
        return SchemaGraph(nodes: nodes, edges: edges)
    }

    private var renderedGraphRevision: Int {
        session.graphRevision &* 31
            &+ layoutRevision &* 7
            &+ session.automationViewRevision
            &+ session.graphVisibleTableIDs.hashValue
    }

    private var initialViewportDocumentKey: String? {
        if session.schemaReview != nil, let url = session.databaseURL { return "schema-review:\(url.absoluteString)" }
        guard let target = session.databaseTarget else { return nil }
        return "\(target.stableStorageKey)|\(session.databaseURL?.absoluteString ?? "")"
    }




    private var focusNodeID: String? {
        guard hoveredRelationTarget == nil else { return nil }
        if session.showAllGraphTableCards {
            return tableFocusNodeID ?? hoveredNodeID ?? (session.selectedGraphNodeIDs.count <= 1 ? session.selectedGraphNodeID : nil)
        }
        return tableFocusNodeID ?? manuallyExpandedNodeID ?? hoveredNodeID ?? (session.selectedGraphNodeIDs.count <= 1 ? session.selectedGraphNodeID : nil)
    }

    private var manuallyExpandedNodeID: String? {
        session.expandedGraphNodeIDs.sorted().first
    }

    private var relatedPreviewByNode: [String: GraphNodeRelationPreview] {
        guard !session.showAllGraphTableCards else { return [:] }

        let relationTarget = tappedRelationTarget
        if relationPreviewCache.isValid,
           relationPreviewCache.graphRevision == session.graphRevision,
           relationPreviewCache.target == relationTarget,
           relationPreviewCache.expandedNodeID == manuallyExpandedNodeID {
            return relationPreviewCache.previews
        }
        var previews: [String: GraphNodeRelationPreview] = [:]
        defer {
            relationPreviewCache.graphRevision = session.graphRevision
            relationPreviewCache.target = relationTarget
            relationPreviewCache.expandedNodeID = manuallyExpandedNodeID
            relationPreviewCache.previews = previews
            relationPreviewCache.isValid = true
        }

        if let relationTarget {
            for edge in renderedGraph.edges where edge.matches(relationTarget) {
                previews[edge.sourceID, default: .empty].foreignKeyColumns.insert(edge.sourceColumn)
                previews[edge.targetID, default: .empty].primaryKeyColumns.insert(edge.targetColumn)
            }
            return previews
        }

        guard let manuallyExpandedNodeID else { return [:] }

        for edge in renderedGraph.edges where edge.sourceID == manuallyExpandedNodeID || edge.targetID == manuallyExpandedNodeID {
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
        let automationRevision = session.automationViewRevision
        GeometryReader { geometry in
            ZStack {
                graphBackground

                if session.graph.nodes.isEmpty {
                    emptyState
                    Canvas { _, _ in
                        guard isGraphViewVisible,
                              session.automationRenderedViewRevision != automationRevision else { return }
                        Task { @MainActor in
                            await Task.yield()
                            guard isGraphViewVisible else { return }
                            session.acknowledgeAutomationViewRendered(revision: automationRevision, displayedTableIDs: [])
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                    graphScene(size: geometry.size)
                    if (session.graphTableFilter.isActive || session.automationVisibleTableIDs != nil)
                        && session.graphVisibleTableIDs.isEmpty {
                        VStack(spacing: 12) {
                            Text("No tables are visible in this graph scope")
                            if session.automationVisibleTableIDs != nil {
                                Button("Return to all") { returnToAllTables(in: geometry.size) }
                            } else {
                                Button("Clear filters") { session.clearGraphFilter() }
                            }
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    graphOverlayControls(size: geometry.size)
                }
            }
            .onAppear {
                isGraphViewVisible = true
                viewportSize = geometry.size
                StudioLog.graph.debug("SchemaGraphView.onAppear settled=\(session.graphLayout.hasSettledLayout, privacy: .public) maximized=\(String(describing: session.maximizedPaneSide), privacy: .public)")
                let hasSessionCamera = initialViewportDocumentKey.map {
                    session.initializedGraphViewportDocument == $0
                } ?? false
                switch initialViewport.appeared(
                    hasGraph: !session.graph.nodes.isEmpty,
                    layoutIsSettled: session.graphLayout.hasRestoredSnapshot || session.graphLayout.hasSettledLayout,
                    hasSessionCamera: hasSessionCamera
                ) {
                case .restoreCamera:
                    setViewport(GraphViewportTransform(zoom: session.graphZoom, pan: session.graphPan), animated: false)
                case .scheduleFit:
                    scheduleInitialViewportFit()
                case .waitForGraph:
                    break
                }
                if let expanded = manuallyExpandedNodeID, !session.showAllGraphTableCards,
                   graphFocusPlan == nil {
                    focusTableConnections(expanded)
                }
                if let command = session.automationFocusCommand {
                    applyAutomationFocus(command, in: geometry.size)
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                if initialViewport.viewportChanged() {
                    scheduleInitialViewportFit()
                    return
                }
                guard !session.graph.nodes.isEmpty, newSize.width > 0, newSize.height > 0 else { return }
                if graphFocusPlan != nil {
                    fitGraphFocusViewport(in: newSize)
                }
            }
            .onChange(of: session.graphTableFilter) { _, _ in
                clearGraphFocusSession(animated: false, restoreViewport: false)
                focusedGroupID = nil
                hoveredNodeID = nil
                clearRelationHoverState()
                session.collapseExpandedGraphNodes()
                layoutRevision &+= 1
                fitGraph(in: geometry.size)
            }
            .onChange(of: session.automationFocusCommand?.id) { _, _ in
                guard let command = session.automationFocusCommand else { return }
                applyAutomationFocus(command, in: geometry.size)
            }
            .onChange(of: session.graphRevision) { _, _ in
                if session.schemaReview?.proposal != nil, initialViewportDocumentKey == session.initializedGraphViewportDocument {
                    clearGraphFocusSession(animated: false, restoreViewport: false)
                    relationPreviewCache.isValid = false
                    invalidateClusterTitleCache()
                    layoutRevision &+= 1
                    return
                }
                focusedGroupID = nil
                focusedGroupPage = 0
                overviewViewport = nil
                relationPreviewCache.isValid = false
                _ = initialViewport.graphChanged(hasGraph: !session.graph.nodes.isEmpty)
                scheduleInitialViewportFit()
            }
            .onChange(of: initialViewportDocumentKey) { _, _ in
                // Different documents can expose an equal catalog graph.
                focusedGroupID = nil
                focusedGroupPage = 0
                overviewViewport = nil
                relationPreviewCache.isValid = false
                _ = initialViewport.graphChanged(hasGraph: !session.graph.nodes.isEmpty)
                scheduleInitialViewportFit()
            }
            .onChange(of: session.schemaSidecarRevision) { _, _ in
                invalidateClusterTitleCache()
            }
            .onChange(of: session.graphGrouping) { _, _ in
                invalidateClusterTitleCache()
                layoutRevision &+= 1
                if let focusedGroupID, session.graphGrouping.group(id: focusedGroupID) == nil {
                    self.focusedGroupID = nil
                    focusedGroupPage = 0
                    overviewViewport = nil
                    fitGraph(in: geometry.size)
                }
            }
            .onChange(of: session.showAllGraphTableCards) { _, isPresented in
                clearGraphFocusSession(animated: false, restoreViewport: false)
                pendingExpansionNodeID = nil
                hoveredNodeID = nil
                clearRelationHoverState()
                switchPresentationMode(isShowingAllCards: isPresented, in: geometry.size)
            }
            .onChange(of: zoom) { _, newZoom in
                scheduleViewportSessionSync(zoom: newZoom, pan: pan)
            }
            .onChange(of: pan) { _, newPan in
                scheduleViewportSessionSync(zoom: zoom, pan: newPan)
            }
            .onDisappear {
                isGraphViewVisible = false
                initialViewportTask?.cancel()
                initialViewportTask = nil
                initialViewport.cancel()
                flushViewportSessionSync()
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
            Text("Open a database to inspect declared foreign keys.")
                .foregroundStyle(StudioPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func graphScene(size: CGSize) -> some View {
        let focusPlan = effectiveFocusPlan
        let geometry = interactionGeometry(in: size, focusPlan: focusPlan)
        let anchorMap = geometry.anchorMap
        let graph = renderedGraph
        let viewport = CGRect(origin: .zero, size: size)
        let displayedTableIDs = Set(geometry.renderPlan.detailIDs.filter {
            geometry.frames[$0]?.intersects(viewport) == true
        }).union(geometry.renderPlan.markerIDs.filter {
            geometry.markerFrames[$0]?.intersects(viewport) == true
        })
        let hoverNeighbors = draggedNodeID == nil
            ? (hoveredNodeID.map { graph.neighbors(of: $0) } ?? [])
            : []
        let hoverSummaryIDs = shows(.hoverPreviews) ? GraphHoverPresentation.summaryIDs(
            hoveredID: draggedNodeID == nil ? hoveredNodeID : nil, connectedIDs: hoverNeighbors,
            markerFrames: geometry.markerFrames, viewport: viewport
        ) : []
        let hoverSummaryNodes = graph.nodes.filter { hoverSummaryIDs.contains($0.id) }
        let renderPlan = geometry.renderPlan
        let edgeLookup = topologyCache.index(for: graph, graphRevision: renderedGraphRevision)
        let currentFocusNodeID = focusNodeID
        let currentHoverTarget = tappedRelationTarget ?? hoveredRelationTarget
        let relationHighlight = cachedRelationHighlight(focusNodeID: currentFocusNodeID,
                                                      hoverTarget: currentHoverTarget, edgeLookup: edgeLookup)
        let renderedNodes = graph.nodes.filter { renderPlan.detailIDs.contains($0.id) }
        let _ = layoutRevision

        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(backgroundPanGesture)
                .onTapGesture { point in
                    if let card = graphCard(at: point, geometry: geometry, edgeLookup: edgeLookup),
                       renderPlan.markerIDs.contains(card.tableID) {
                        revealTable(card.tableID, in: size)
                        return
                    }
                    let changesView = graphFocusTableRelation != nil
                        || !pulledGraphPositions.isEmpty
                        || manuallyExpandedNodeID != nil
                        || !session.selectedGraphNodeIDs.isEmpty
                        || session.selectedGraphNodeID != nil
                    if changesView { session.notifyManualGraphInteraction() }
                    if graphFocusTableRelation != nil || !pulledGraphPositions.isEmpty {
                        clearGraphFocusSession()
                    }
                    if let expandedID = manuallyExpandedNodeID {
                        toggleExpandedState(for: expandedID, in: viewportSize)
                    }
                    session.clearGraphSelection()
                }

            GraphTrackpadInputSurface(
                ignoresInput: false,
                geometryRevision: geometry.revision,
                onPan: { delta in
                    if applyTrackpadPan(delta) { session.notifyManualGraphInteraction() }
                },
                onMagnify: { magnification, anchor in
                    if applyTrackpadMagnification(magnification, anchor: anchor, in: size) {
                        session.notifyManualGraphInteraction()
                    }
                },
                onPointerMove: { point in
                    handleViewportPointerMove(point, geometry: geometry, edgeLookup: edgeLookup)
                },
                onInteractionEnded: { flushViewportSessionSync() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            Canvas { context, canvasSize in
                drawClusterTitles(in: &context, canvasSize: canvasSize)
            }
            .allowsHitTesting(false)

            let isOverviewOnly = usesOverviewMarks && focusPlan == nil
            let hoverHighlight = isOverviewOnly ? hoveredNodeID.map {
                GraphRelationHighlight(graph: graph, focusNodeID: $0, edgeLookup: edgeLookup)
            } : nil
            let edgePlan = edgeLayerPlan(isOverviewOnly: isOverviewOnly, focusPlan: focusPlan,
                                         relationHighlight: relationHighlight, hoverHighlight: hoverHighlight)

            Canvas { context, _ in
                if isOverviewOnly, session.schemaReview == nil, shows(.overviewGroupLinks) {
                    drawGroupConnections(in: &context, size: size)
                }
                if let edgePlan {
                    drawEdges(in: &context, anchorMap: anchorMap, plan: edgePlan)
                }
                drawOverviewMarks(in: &context, frames: geometry.markerFrames, connectedIDs: hoverNeighbors)
                for id in hoverSummaryIDs {
                    guard let mark = geometry.markerFrames[id], let summary = context.resolveSymbol(id: id) else { continue }
                    let frame = GraphHoverPresentation.summaryFrame(in: mark, referenceSize: summary.size)
                    var nodeContext = context
                    nodeContext.translateBy(x: frame.minX, y: frame.minY)
                    nodeContext.scaleBy(x: frame.width / summary.size.width, y: frame.height / summary.size.height)
                    nodeContext.draw(summary, at: .zero, anchor: .topLeading)
                }
                if isGraphViewVisible,
                   session.automationRenderedViewRevision != session.automationViewRevision {
                    let revision = session.automationViewRevision
                    Task { @MainActor in
                        await Task.yield()
                        guard isGraphViewVisible else { return }
                        session.acknowledgeAutomationViewRendered(
                            revision: revision,
                            displayedTableIDs: displayedTableIDs
                        )
                    }
                }
            } symbols: {
                ForEach(hoverSummaryNodes) { node in
                    GraphNodeSummary(
                        title: node.title,
                        fieldCount: session.descriptor(named: node.id)?.columns.count ?? 0,
                        rowCount: session.graphRowCounts[node.id] ?? session.descriptor(named: node.id)?.rowCount,
                        schemaChange: session.schemaReviewChanges[node.id]
                    )
                    .padding(.horizontal, GraphCardLayout.horizontalInset)
                    .frame(width: GraphCardLayout.collapsedWidth(title: node.title, hovered: false),
                           height: GraphCardLayout.collapsedHeight)
                    .tag(node.id)
                }
            }
            .allowsHitTesting(false)

            // Signals follow exactly the relations the layer above painted, so the
            // pulse layer stays idle — and unbuilt — whenever no line is drawn.
            let pulseTracks = animatesRelationPulses ? (edgePlan.map {
                cachedEdgePulseTracks(anchorMap: anchorMap, plan: $0, geometryRevision: geometry.revision)
            } ?? []) : []

            if !pulseTracks.isEmpty {
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        GraphEdgePulseRenderer.draw(
                            in: &context,
                            tracks: pulseTracks,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
                .allowsHitTesting(false)
            }

            ForEach(renderedNodes) { node in
                let descriptor = session.descriptor(named: node.id)
                let outgoingEdges = edgeLookup.outgoingEdges(for: node.id)
                let incomingEdges = edgeLookup.incomingEdges(for: node.id)
                let previewColumns = previewColumns(for: node.id)
                let displayStyle = nodeDisplayStyle(for: node.id, previewColumns: previewColumns)
                let cardSize = nodeSize(for: node.id)
                let scrollOffset = cardScrollOffsets[node.id] ?? 0

                let isMultiSelected = session.selectedGraphNodeIDs.count > 1 && session.selectedGraphNodeIDs.contains(node.id)

                GraphNodeCardView(
                    node: node,
                    descriptor: descriptor,
                    rowCount: session.graphRowCounts[node.id] ?? descriptor?.rowCount,
                    tableDescription: session.tableDescription(for: node.id),
                    clusterLabel: session.clusterLabel(for: node.id),
                    clusterColor: clusterBorderColor(for: node.id),
                    columnDescription: { session.columnDescription(for: node.id, column: $0) },
                    previewColumns: previewColumns,
                    outgoingEdges: outgoingEdges,
                    incomingEdges: incomingEdges,
                    isSelected: session.selectedGraphNodeIDs.contains(node.id),
                    isMultiSelected: isMultiSelected,
                    viewportZoom: zoom,
                    displayStyle: displayStyle,
                    isFocusRoot: tableFocusNodeID == node.id || graphFocusTableRelation?.tableID == node.id,
                    scrollOffset: scrollOffset,
                    isHovered: hoveredNodeID == node.id,
                    isDragging: draggedNodeID == node.id,
                    highlightState: relationHighlight.highlightState(for: node.id),
                    keepsTextReadableWhenZoomed: focusPlan != nil || hoveredNodeID == node.id || hoverNeighbors.contains(node.id),
                    schemaChange: session.schemaReviewChanges[node.id],
                    selectNode: {
                        session.notifyManualGraphInteraction()
                        clearGraphFocusSession()
                        withAnimation(.snappy(duration: 0.16)) {
                            session.selectGraphNode(node.id)
                        }
                    },
                    toggleExpanded: {
                        session.notifyManualGraphInteraction()
                        toggleExpandedState(for: node.id, in: size)
                    },
                    openTable: {
                        session.notifyManualGraphInteraction()
                        withAnimation(.snappy(duration: 0.16)) {
                            session.selectGraphNode(node.id)
                        }
                        _ = session.openTable(named: node.id)
                    },
                    showTopRows: {
                        session.notifyManualGraphInteraction()
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
                        session.notifyManualGraphInteraction()
                        pullConnectedNodesIntoView(for: target)
                    },
                    headerDragGesture: nodeDragGesture(nodeID: node.id, in: size)
                )
                .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
                .scaleEffect(zoom * GraphHoverPresentation.cardScale(hovered: hoveredNodeID == node.id && draggedNodeID == nil, connected: hoverNeighbors.contains(node.id)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredNodeID)
                .position(screenCenter(for: node.id, in: size))
                .opacity(focusOpacity(for: focusPlan?.tierForTable(node.id)))
                .shadow(
                    color: shows(.cardShadows)
                        ? StudioPalette.shadow.opacity(session.showAllGraphTableCards ? 0.38 : 0.8)
                        : .clear,
                    radius: shows(.cardShadows) ? shadowRadius(for: node.id) : 0,
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

    @ViewBuilder
    private func graphNavigationControls(in size: CGSize) -> some View {
        if session.automationVisibleTableIDs != nil {
            Button { returnToAllTables(in: size) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Return to all tables")
            .accessibilityLabel("Return to all tables")
        }

        if let focusPlan = graphFocusPlan, focusPlan.isActive {
            Button {
                session.notifyManualGraphInteraction()
                clearGraphFocusSession()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Leave focus: \(graphFocusSummary(focusPlan: focusPlan))")
            .accessibilityLabel("Return to overview")

            if let target = graphFocusTableRelation {
                let page = GraphExploration.pageOrdered(relatedNodeIDs(for: target), index: relationPageIndex)
                if page.count > 1 {
                    graphPageControls(index: page.index, count: page.count) {
                        session.notifyManualGraphInteraction()
                        pullConnectedNodesIntoView(for: target, pageIndex: page.index - 1)
                    } next: {
                        session.notifyManualGraphInteraction()
                        pullConnectedNodesIntoView(for: target, pageIndex: page.index + 1)
                    }
                }
            } else if let nodeID = tableFocusNodeID {
                let page = tableConnectionPage(nodeID)
                if page.count > 1 {
                    graphPageControls(index: page.index, count: page.count) {
                        session.notifyManualGraphInteraction()
                        focusTableConnections(nodeID, pageIndex: page.index - 1)
                    } next: {
                        session.notifyManualGraphInteraction()
                        focusTableConnections(nodeID, pageIndex: page.index + 1)
                    }
                }
            }
        } else if let group = session.graphGrouping.group(id: focusedGroupID ?? "") {
            Button { showGraphOverview(in: size) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Return from \(group.label) to all groups")
            .accessibilityLabel("Return to all groups")

            let page = GraphExploration.pageOrdered(group.nodeIDs, index: focusedGroupPage)
            if page.count > 1 {
                graphPageControls(index: page.index, count: page.count) {
                    focusGroup(group.id, pageIndex: page.index - 1, in: size)
                } next: {
                    focusGroup(group.id, pageIndex: page.index + 1, in: size)
                }
            }
        }
    }

    private func graphPageControls(index: Int, count: Int, previous: @escaping () -> Void, next: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: previous) { Image(systemName: "chevron.left") }
                .disabled(index == 0).help("Previous tables")
            Text("\(index + 1)/\(count)").font(.caption).monospacedDigit()
            Button(action: next) { Image(systemName: "chevron.right") }
                .disabled(index + 1 == count).help("Next tables")
        }
    }

    private func returnToAllTables(in size: CGSize) {
        session.notifyManualGraphInteraction()
        session.setAutomationVisibleTableIDs(nil)
        clearGraphFocusSession(animated: false, restoreViewport: false)
        session.clearGraphSelection()
        fitGraph(in: size)
    }

    private func applyAutomationFocus(_ command: AutomationGraphFocusCommand, in size: CGSize) {
        let graph = renderedGraph
        guard graph.contains(nodeID: command.tableID) else { return }
        session.selectGraphNode(command.tableID)
        prepareTableNavigation()

        let relationWasRequested = command.relationID != nil
            || command.sourceColumn != nil || command.targetColumn != nil
        guard relationWasRequested else {
            focusTableConnections(command.tableID)
            return
        }

        let edge = graph.edges.first { edge in
            if let relationID = command.relationID, edge.id != relationID { return false }
            if let sourceColumn = command.sourceColumn, edge.sourceColumn != sourceColumn { return false }
            if let targetColumn = command.targetColumn, edge.targetColumn != targetColumn { return false }
            return edge.sourceID == command.tableID || edge.targetID == command.tableID
        }
        guard let edge else { return }
        let columnName: String
        if edge.sourceID == command.tableID {
            columnName = command.sourceColumn ?? edge.sourceColumn
        } else {
            columnName = command.targetColumn ?? edge.targetColumn
        }
        pullConnectedNodesIntoView(
            for: GraphRelationHoverTarget(tableID: command.tableID, columnName: columnName, endpointKind: .column)
        )
        if size != .zero { fitGraphFocusViewport(in: size) }
    }

    private func focusGroup(_ groupID: String, pageIndex: Int = 0, in size: CGSize) {
        guard let group = session.graphGrouping.group(id: groupID) else { return }
        session.notifyManualGraphInteraction()
        prepareTableNavigation()
        rememberOverviewViewport()
        clearGraphFocusSession(restoreViewport: false)
        session.collapseExpandedGraphNodes()
        session.clearGraphSelection()
        focusedGroupID = groupID
        focusedGroupPage = GraphExploration.pageOrdered(group.nodeIDs, index: pageIndex).index
        hoveredNodeID = nil
        clearRelationHoverState()
        isGraphNavigatorPresented = false
        invalidateClusterTitleCache()
        let ids = GraphExploration.pageOrdered(group.nodeIDs, index: focusedGroupPage).ids
        let bounds = ids.compactMap { graphFrame(for: $0) }.reduce(CGRect.null) { $0.union($1) }
        setViewport(GraphViewportTransform.fit(contentBounds: bounds, in: size, padding: 120, minZoom: 0.05, maxZoom: 1.05), animated: true)
    }

    private func showGraphOverview(in size: CGSize) {
        session.notifyManualGraphInteraction()
        prepareTableNavigation()
        clearGraphFocusSession(restoreViewport: false)
        focusedGroupID = nil
        focusedGroupPage = 0
        session.collapseExpandedGraphNodes()
        session.clearGraphSelection()
        hoveredNodeID = nil
        clearRelationHoverState()
        isGraphNavigatorPresented = false
        invalidateClusterTitleCache()
        let previous = overviewViewport
        overviewViewport = nil
        if let restored = previous?.restored(for: presentationMode) {
            setViewport(restored, animated: true)
        } else {
            fitGraph(in: size)
        }
    }

    private func revealTable(_ nodeID: String, in size: CGSize) {
        guard session.graph.contains(nodeID: nodeID) else { return }
        session.notifyManualGraphInteraction()
        prepareTableNavigation()
        rememberOverviewViewport()
        clearGraphFocusSession(restoreViewport: false)
        focusedGroupID = nil
        session.selectGraphNode(nodeID)
        hoveredNodeID = nil
        clearRelationHoverState()
        isGraphNavigatorPresented = false
        invalidateClusterTitleCache()
        openExpandedNode(nodeID, in: size)
    }

    private func fitTable(_ nodeID: String, in size: CGSize) {
        let point = graphNodePoint(for: nodeID)
        let cardSize = nodeSize(for: nodeID)
        let bounds = CGRect(x: point.x - cardSize.width / 2, y: point.y - cardSize.height / 2,
                            width: cardSize.width, height: cardSize.height)
        setViewport(GraphViewportTransform.fit(contentBounds: bounds, in: size, padding: 160,
                                               minZoom: 0.45, maxZoom: 1.05), animated: true)
    }

    private func rememberOverviewViewport() {
        guard overviewViewport == nil else { return }
        overviewViewport = GraphViewportBookmark(transform: GraphViewportTransform(zoom: zoom, pan: pan), presentation: presentationMode)
    }

    private func prepareTableNavigation() {
        clearGraphFocusSession(restoreViewport: false)
    }

    private func drawOverviewMarks(in context: inout GraphicsContext, frames: [String: CGRect], connectedIDs: Set<String>) {
        for (id, mark) in frames {
            let color = clusterBorderColor(for: id) ?? StudioPalette.accent
            let isHovered = hoveredNodeID == id
            let connected = connectedIDs.contains(id)
            let emphasis = isHovered || connected ? 0.78 : 0.62
            let opacity = emphasis * (session.schemaReviewChanges[id]?.kind == .removed ? 0.6 : 1)
            let path = Path(roundedRect: mark, cornerRadius: min(4, mark.height / 2))
            let isUnknown = session.graphNodeSizeProfile.unknownIDs.contains(id)
            context.fill(path, with: .color(color.opacity(isUnknown ? opacity * 0.45 : opacity)))
            if let change = session.schemaReviewChanges[id], change.kind != .unchanged {
                context.stroke(path, with: .color(.white), lineWidth: 4)
                context.stroke(path, with: .color(change.kind.tint), style: StrokeStyle(lineWidth: 2, dash: change.kind == .removed ? [3, 2] : []))
            }
            if isUnknown {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            if session.selectedGraphNodeIDs.contains(id) {
                context.stroke(path, with: .color(StudioPalette.primaryText), lineWidth: 1.5)
            }
        }
    }

    private func drawGroupConnections(in context: inout GraphicsContext, size: CGSize) {
        let key = GraphGroupGeometryKey(graphRevision: renderedGraphRevision,
                                        groupingRevision: session.graphGroupingRevision, layoutRevision: layoutRevision)
        if scenePreparation.groupGeometryKey != key {
            var centers: [String: CGPoint] = [:]
            let renderedNodeIDs = Set(renderedGraph.nodes.map(\.id))
            for group in session.graphGrouping.groups where !group.nodeIDs.isEmpty {
                let memberIDs = GraphVisibleGroupMembers.intersection(
                    group.nodeIDs, renderedNodeIDs: renderedNodeIDs
                )
                guard !memberIDs.isEmpty else { continue }
                let sum = memberIDs.reduce(CGPoint.zero) { sum, id in
                    let point = session.graphLayout.position(for: id)
                    return CGPoint(x: sum.x + point.x, y: sum.y + point.y)
                }
                centers[group.id] = CGPoint(x: sum.x / CGFloat(memberIDs.count), y: sum.y / CGFloat(memberIDs.count))
            }
            scenePreparation.groupGeometryKey = key
            scenePreparation.groupCenters = centers
        }
        let transform = GraphViewportTransform(zoom: zoom, pan: pan)
        let centers = scenePreparation.groupCenters.mapValues { transform.point(for: $0, in: size) }
        let links = topologyCache.groupLinks(for: renderedGraph, graphRevision: renderedGraphRevision,
                                            membership: session.graphGrouping.nodeToGroup,
                                            groupingRevision: session.graphGroupingRevision)
        for link in links {
            guard let source = centers[link.sourceID], let target = centers[link.targetID] else { continue }
            let path = edgePath(from: source, to: target)
            guard path.boundingRect.insetBy(dx: -4, dy: -4).intersects(CGRect(origin: .zero, size: size)) else { continue }
            context.stroke(path, with: .color(StudioPalette.edgeNeutral.opacity(0.18)),
                           lineWidth: min(2.5, 0.6 + log2(CGFloat(link.count) + 1) * 0.25))
        }
    }

    private func drawClusterTitles(in context: inout GraphicsContext, canvasSize: CGSize) {
        let focusPlan = effectiveFocusPlan
        guard shows(.groupTitles), session.showClusterHalos || focusPlan != nil else { return }

        let titleStyle = (fontSize: CGFloat(15), padding: CGFloat(22))
        let cacheKey = clusterTitleCacheToken(focusPlan: focusPlan)

        if clusterTitleCache.cacheKey != cacheKey {
            if let focusPlan {
                clusterTitleCache.entries = focusClusterTitleEntries(focusPlan: focusPlan, padding: titleStyle.padding)
            } else {
                clusterTitleCache.entries = tableClusterTitleEntries(padding: titleStyle.padding)
            }
            clusterTitleCache.cacheKey = cacheKey
        }

        guard !clusterTitleCache.entries.isEmpty else { return }

        let viewportTransform = GraphViewportTransform(zoom: zoom, pan: pan)
        let inFocusLayout = focusPlan != nil
        let isOverview = isLargeGraph && !inFocusLayout
        let entries = isOverview ? clusterTitleCache.entries.sorted {
            let a = $0.path.boundingRect, b = $1.path.boundingRect
            let areaA = a.width * a.height, areaB = b.width * b.height
            return areaA == areaB ? ($0.label ?? "") < ($1.label ?? "") : areaA > areaB
        } : clusterTitleCache.entries
        var occupiedLabels: [CGRect] = []

        for entry in entries {
            guard let label = entry.label, !label.isEmpty else { continue }
            let labelPoint: CGPoint
            if let anchor = entry.labelAnchor {
                labelPoint = viewportTransform.point(for: anchor, in: canvasSize)
            } else {
                let screenPath = entry.path.applying(
                    CGAffineTransform(scaleX: zoom, y: zoom)
                        .concatenating(CGAffineTransform(
                            translationX: canvasSize.width / 2 + pan.width,
                            y: canvasSize.height / 2 + pan.height
                        ))
                )
                let bounds = screenPath.boundingRect
                labelPoint = CGPoint(x: bounds.midX, y: bounds.minY - 6)
            }
            let labelFontSize: CGFloat = isLargeGraph && !inFocusLayout ? 11 : titleStyle.fontSize
            let characterBudget = max(10, Int(entry.path.boundingRect.width * zoom / (labelFontSize * 0.62)))
            let displayLabel: String
            if isLargeGraph && !inFocusLayout && label.count > characterBudget {
                displayLabel = String(label.prefix(max(3, characterBudget - 7))) + "…" + String(label.suffix(6))
            } else {
                displayLabel = label
            }
            let resolved = context.resolve(
                Text(displayLabel.uppercased())
                    .font(.system(size: labelFontSize, weight: .bold, design: .rounded))
                    // A group's own tint, unless the reader switched group colour off — in
                    // which case the name still belongs on screen, just in plain ink.
                    .foregroundStyle((shows(.groupColors) ? entry.color : StudioPalette.secondaryText)
                        .opacity(inFocusLayout ? 0.96 : 0.85))
            )
            if isOverview {
                let measured = resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                let frame = CGRect(x: labelPoint.x - measured.width / 2, y: labelPoint.y - measured.height,
                                   width: measured.width, height: measured.height).insetBy(dx: -4, dy: -3)
                guard frame.intersects(CGRect(origin: .zero, size: canvasSize)),
                      !occupiedLabels.contains(where: { $0.intersects(frame) }) else { continue }
                occupiedLabels.append(frame)
            }
            context.draw(resolved, at: labelPoint, anchor: .bottom)
        }
    }

    private func tableClusterTitleEntries(padding pad: CGFloat, focusPlan: GraphFocusPlan? = nil) -> [ClusterTitleCache.Entry] {
        let renderedNodeIDs = Set(renderedGraph.nodes.map(\.id))
        let schemas = Set(session.tables.filter { renderedNodeIDs.contains($0.id) }.compactMap(\.schemaName))
        return session.graphGrouping.groups.compactMap { group in
            guard let color = Color(studioHex: group.colorHex) else { return nil }
            let memberIDs = GraphVisibleGroupMembers.intersection(
                group.nodeIDs, renderedNodeIDs: renderedNodeIDs
            )
            let frames = memberIDs.compactMap { name -> CGRect? in
                if let focusPlan, focusPlan.tierForTable(name) == .hidden { return nil }
                let point = graphNodePoint(for: name)
                let size = nodeSize(for: name)
                return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
            }
            guard !frames.isEmpty else { return nil }
            var label = group.label
            if group.isInferred, schemas.count == 1, let schema = schemas.first,
               label.hasPrefix(schema + " · ") {
                label = String(label.dropFirst(schema.count + 3))
            }
            return makeFocusClusterTitleEntry(color: color, label: "\(label) · \(frames.count)",
                                              frames: frames, padding: pad, labelGap: 30)
        }
    }

    private func focusClusterTitleEntries(focusPlan: GraphFocusPlan, padding pad: CGFloat) -> [ClusterTitleCache.Entry] {
        var entries: [ClusterTitleCache.Entry] = []
        let renderedNodeIDs = Set(renderedGraph.nodes.map(\.id))
        let labelGap: CGFloat = 30

        for cluster in session.graphGrouping.groups {
            guard let color = Color(studioHex: cluster.colorHex) else { continue }
            let memberIDs = GraphVisibleGroupMembers.intersection(
                cluster.nodeIDs, renderedNodeIDs: renderedNodeIDs
            )
            let frames = memberIDs.compactMap { name -> CGRect? in
                guard focusPlan.tierForTable(name) != .hidden else { return nil }
                let center = graphNodePoint(for: name)
                let size = nodeSize(for: name)
                return CGRect(
                    x: center.x - size.width / 2,
                    y: center.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            }
            guard !frames.isEmpty else { continue }
            entries.append(
                makeFocusClusterTitleEntry(
                    color: color,
                    label: cluster.label,
                    frames: frames,
                    padding: pad,
                    labelGap: labelGap
                )
            )
        }

        return entries
    }

    private func makeFocusClusterTitleEntry(
        color: Color,
        label: String?,
        frames: [CGRect],
        padding: CGFloat,
        labelGap: CGFloat
    ) -> ClusterTitleCache.Entry {
        let bounds = frames.reduce(CGRect.null) { partial, frame in
            partial.isNull ? frame : partial.union(frame)
        }
        let padded = bounds.insetBy(dx: -padding, dy: -padding)
        let path = Path(roundedRect: padded, cornerRadius: min(max(padded.height / 4, 18), 52))
        let minY = frames.map(\.minY).min() ?? bounds.minY
        let centroidX = frames.map(\.midX).reduce(0, +) / CGFloat(max(frames.count, 1))
        let labelAnchor = CGPoint(x: centroidX, y: minY - labelGap)
        return ClusterTitleCache.Entry(color: color, path: path, label: label, labelAnchor: labelAnchor)
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


    private func tableLinkLimit(isEmphasized: Bool) -> Int {
        if isEmphasized { return 12 }
        if zoom < 0.55 { return 1 }
        if zoom < 0.85 { return 2 }
        return 3
    }




    /// Builds the plan for the relation layer, or `nil` when it paints nothing.
    ///
    /// One plan serves both the static lines and the pulses, so a signal can never travel
    /// along a relation whose line is hidden.
    private func edgeLayerPlan(
        isOverviewOnly: Bool,
        focusPlan: GraphFocusPlan?,
        relationHighlight: GraphRelationHighlight,
        hoverHighlight: GraphRelationHighlight?
    ) -> GraphEdgeLayerPlan? {
        let mode = GraphEdgeLayerPlan.mode(isOverview: isOverviewOnly,
                                           isSchemaReview: session.schemaReview != nil,
                                           showsOverviewRelations: shows(.overviewRelations),
                                           hasHover: hoverHighlight != nil)
        switch mode {
        case nil:
            return nil
        case .detail:
            return GraphEdgeLayerPlan(highlight: relationHighlight, focusPlan: focusPlan,
                                      onlyHighlighted: false, sampleLimit: nil, inkScale: 1)
        case .overviewSample:
            return GraphEdgeLayerPlan(highlight: hoverHighlight ?? relationHighlight, focusPlan: nil,
                                      onlyHighlighted: false,
                                      sampleLimit: GraphEdgeLayerPlan.overviewRelationLimit,
                                      inkScale: GraphEdgeLayerPlan.overviewInkScale)
        case .overviewHoverOnly:
            return GraphEdgeLayerPlan(highlight: hoverHighlight ?? relationHighlight, focusPlan: nil,
                                      onlyHighlighted: true, sampleLimit: nil, inkScale: 1)
        }
    }

    /// Resolves the relations a plan paints: graph order, screen anchors, the curve the
    /// static layer strokes, and whether the reader is focused on each one.
    private func visibleEdgeRenders(anchorMap: GraphAnchorMap, plan: GraphEdgeLayerPlan) -> [GraphEdgeRender] {
        let highlighted = plan.highlight.highlightedEdgeIDs
        // Sampling the filtered edge list before resolving anchors bounds the work and
        // prevents filtered tables from resurfacing in the overview.
        let candidates = plan.sampleLimit.map { limit in
            GraphEdgeSampling.evenSample(renderedGraph.edges, limit: limit) { highlighted.contains($0.id) }
        } ?? renderedGraph.edges

        let viewport = CGRect(origin: .zero, size: viewportSize)
        var renders: [GraphEdgeRender] = []
        renders.reserveCapacity(min(candidates.count, 512))
        for edge in candidates {
            if plan.onlyHighlighted && !highlighted.contains(edge.id) { continue }
            if let focusPlan = plan.focusPlan {
                let sourceVisible = focusPlan.tierForTable(edge.sourceID) != .hidden
                let targetVisible = focusPlan.tierForTable(edge.targetID) != .hidden
                guard sourceVisible, targetVisible else { continue }
            }
            guard let anchors = anchorMap.edgeAnchors(for: edge) else { continue }

            var (control1, control2) = edgeControlPoints(from: anchors.source, to: anchors.target)
            // Both versions of an edited FK remain visible even with equal endpoints.
            if session.schemaReview != nil {
                if edge.id.hasPrefix("before:") { control1.x -= 18; control2.x -= 18 }
                if edge.id.hasPrefix("after:") { control1.x += 18; control2.x += 18 }
            }
            var path = Path()
            path.move(to: anchors.source)
            path.addCurve(to: anchors.target, control1: control1, control2: control2)
            guard path.boundingRect.insetBy(dx: -8, dy: -8).intersects(viewport) else { continue }
            renders.append(GraphEdgeRender(
                edge: edge,
                anchors: anchors,
                control1: control1,
                control2: control2,
                path: path,
                isHighlighted: highlighted.contains(edge.id)
            ))
        }
        return renders
    }

    private func drawEdges(in context: inout GraphicsContext, anchorMap: GraphAnchorMap, plan: GraphEdgeLayerPlan) {
        let baseOpacity = (session.showAllGraphTableCards ? 0.48 : 0.34) * plan.inkScale
        let baseWidth = (session.showAllGraphTableCards ? 1.25 : 1.05) * plan.inkScale

        for render in visibleEdgeRenders(anchorMap: anchorMap, plan: plan) {
            let edge = render.edge
            let anchors = render.anchors
            let isHighlighted = render.isHighlighted
            let path = render.path
            let change = session.schemaReviewEdgeChanges[edge.id] ?? .unchanged
            let strokeColor = change != .unchanged ? change.tint : isHighlighted
                ? StudioPalette.edgeHighlight
                : StudioPalette.edgeNeutral.opacity(baseOpacity)

            if isHighlighted {
                context.stroke(
                    path,
                    with: .color(StudioPalette.edgeHighlight.opacity(0.12)),
                    style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round)
                )
            }

            if change != .unchanged {
                context.stroke(path, with: .color(.white.opacity(0.95)), lineWidth: 5)
            }
            context.stroke(
                path,
                with: .color(strokeColor),
                style: StrokeStyle(
                    lineWidth: change != .unchanged ? 2.5 : (isHighlighted ? 1.85 : baseWidth),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: change == .removed ? [6, 4] : []
                )
            )
            if change != .unchanged {
                let midpoint = bezierPoint(start: anchors.source, control1: render.control1,
                                           control2: render.control2, end: anchors.target,
                                           t: change == .removed ? 0.43 : 0.57)
                context.draw(Text(change.symbol).font(.system(size: 16, weight: .heavy)).foregroundStyle(change.tint), at: midpoint)
            }

            if isHighlighted {
                drawDirectionMarker(in: &context, from: anchors.source, control1: render.control1,
                                    control2: render.control2, to: anchors.target, color: StudioPalette.edgeHighlight)
                if shows(.relationshipLabels) {
                    drawCardinalityLabels(in: &context, edge: edge, start: anchors.source,
                                          control1: render.control1, control2: render.control2, end: anchors.target)
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
            HStack(spacing: 6) {
                graphNavigationControls(in: size)

                Button { isGraphNavigatorPresented.toggle() } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find any table or group")
                .accessibilityLabel("Find tables and groups")
                .popover(isPresented: $isGraphNavigatorPresented) {
                    GraphNavigatorView(
                        graph: renderedGraph, grouping: session.graphGrouping,
                        onGroup: { focusGroup($0, in: size) },
                        onTable: { revealTable($0, in: size) },
                        onOverview: { showGraphOverview(in: size) }
                    )
                }

                Button { isGraphFilterPresented = true } label: {
                    Label("Filter", systemImage: session.graphTableFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .tint(session.graphTableFilter.isActive ? StudioPalette.accent : nil)
                .help(session.graphTableFilter.isActive ? "Edit active filters" : "Filter by fields, rows, and relations")
                .popover(isPresented: $isGraphFilterPresented) { GraphFilterEditor(session: session) }

                graphOptionsMenu(in: size)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                graphControlsHeight = height
                if graphFocusPlan != nil { fitGraphFocusViewport(in: size) }
            }
            .background(StudioPalette.chromeFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(StudioPalette.border, lineWidth: 1) }
            .shadow(color: StudioPalette.shadow.opacity(0.45), radius: 10, y: 5)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Back to Content button (center, shown when no nodes visible)
            if shouldShowBackToContent(in: size) {
                Button {
                    session.notifyManualGraphInteraction()
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

    /// The same toggles the menu bar offers, so the canvas menu and View ▸ Graph Visuals
    /// can never drift apart.
    @ViewBuilder
    private var graphVisualToggles: some View {
        GraphVisualToggles(session: session)
    }

    private func graphOptionsMenu(in size: CGSize) -> some View {
        Menu {
            Text(session.graphTableFilter.isActive
                 ? "\(session.graphVisibleTableIDs.count) of \(session.tables.count) tables"
                 : "\(session.graph.nodes.count) tables · \(session.graphGrouping.groupCount) groups")
            if session.graphTableFilter.isActive {
                Button("Clear filter") { session.clearGraphFilter() }
            }
            Divider()
            Menu("Node size") {
                Picker("Node size", selection: Binding(
                    get: { session.graphNodeSizeMetric },
                    set: { session.setGraphNodeSizeMetric($0, persist: true); session.notifyManualGraphInteraction() }
                )) {
                    ForEach(GraphNodeSizeMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.inline)
            }
            Toggle("Expand all tables", isOn: Binding(
                get: { session.showAllGraphTableCards },
                set: { session.setShowAllGraphTableCards($0) }
            ))
            Menu("Graph visuals") {
                graphVisualToggles
            }
            Divider()
            Button("Relayout") {
                session.reloadSchemaSidecarFromDisk()
                session.clearPersistedGraphLayout()
                invalidateClusterTitleCache()
                rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Graph options")
        .accessibilityLabel("Graph options")
        .fixedSize()
    }











    private func highlightedText(_ text: String, query: String, font: Font, matchFont: Font) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return Text(text).font(font) }

        var result = Text("")
        var searchStart = text.startIndex
        let fullRange = text.startIndex..<text.endIndex

        while searchStart < text.endIndex,
              let match = text.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            if searchStart < match.lowerBound {
                result = result + Text(String(text[searchStart..<match.lowerBound])).font(font)
            }
            result = result + Text(String(text[match])).font(matchFont)
            searchStart = match.upperBound
        }

        if searchStart < fullRange.upperBound {
            result = result + Text(String(text[searchStart..<fullRange.upperBound])).font(font)
        }

        return result
    }





















    private func scrollRelationColumnIntoView(_ target: GraphRelationHoverTarget) {
        guard let descriptor = session.descriptor(named: target.tableID),
              let index = descriptor.columns.firstIndex(where: { $0.name == target.columnName }),
              descriptor.columns.count > GraphCardLayout.maxExpandedVisibleRows
        else {
            return
        }

        let maxOffset = CGFloat(descriptor.columns.count - GraphCardLayout.maxExpandedVisibleRows) * GraphCardLayout.expandedRowHeight
        let desiredIndex = max(index - 2, 0)
        cardScrollOffsets[target.tableID] = min(maxOffset, CGFloat(desiredIndex) * GraphCardLayout.expandedRowHeight)
    }



    private func firstValidTable(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate, session.graph.contains(nodeID: candidate) else { continue }
            return candidate
        }
        return nil
    }

    private func appendUnique(_ tableID: String?, to tableIDs: inout [String]) {
        guard let tableID, session.graph.contains(nodeID: tableID), !tableIDs.contains(tableID) else { return }
        tableIDs.append(tableID)
    }

    private func compactCreatedAt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No timestamp" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        let date = isoFormatter.date(from: trimmed) ?? fallbackFormatter.date(from: trimmed)
        guard let date else {
            return trimmed
                .replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
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
                if !isViewportPanning { session.notifyManualGraphInteraction() }
                isViewportPanning = true
                
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
                isViewportPanning = false
                
                if selectionRectStart != nil {
                    // Finish selection
                    selectionRectStart = nil
                    selectionRectCurrent = nil
                } else {
                    panStart = pan
                }
                flushViewportSessionSync()
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
        
        let transform = GraphViewportTransform(zoom: zoom, pan: pan)
        let worldRect = CGRect(origin: transform.graphPoint(for: rect.origin, in: canvasSize),
                               size: CGSize(width: rect.width / zoom, height: rect.height / zoom))
        let selectedNodes = GraphExploration.selection(in: worldRect, frames: worldFrames(focusPlan: effectiveFocusPlan))
        session.setGraphSelection(selectedNodes)
    }

    private func nodeDragGesture(nodeID: String, in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("graphViewport"))
            .onChanged { value in
                if draggedNodeID != nodeID {
                    session.notifyManualGraphInteraction()
                    draggedNodeID = nodeID
                    let currentGraphPoint = graphNodePoint(for: nodeID)
                    nodeDragOrigin = currentGraphPoint
                    let startGraphPoint = GraphViewportTransform(zoom: zoom, pan: pan)
                        .graphPoint(for: value.startLocation, in: canvasSize)
                    nodeDragPointerOffset = CGSize(
                        width: startGraphPoint.x - currentGraphPoint.x,
                        height: startGraphPoint.y - currentGraphPoint.y
                    )
                    draggedNodeUsesFocusPull = isFocusRelatedTable(nodeID)
                    hoveredNodeID = nil
                    clearRelationHoverState()
                    if !draggedNodeUsesFocusPull {
                        if !pulledGraphPositions.isEmpty {
                            clearGraphFocusSession(restoreViewport: false)
                        } else {
                            tappedRelationTarget = nil
                        }
                    }

                    if !session.selectedGraphNodeIDs.contains(nodeID) {
                        session.selectGraphNode(nodeID)
                    }
                    multiNodeDragOrigins = Dictionary(
                        uniqueKeysWithValues: session.selectedGraphNodeIDs.map { ($0, graphNodePoint(for: $0)) }
                    )
                }

                guard draggedNodeID == nodeID else { return }
                let currentGraphPoint = GraphViewportTransform(zoom: zoom, pan: pan)
                    .graphPoint(for: value.location, in: canvasSize)
                let moved = CGPoint(
                    x: currentGraphPoint.x - (nodeDragPointerOffset?.width ?? 0),
                    y: currentGraphPoint.y - (nodeDragPointerOffset?.height ?? 0)
                )

                if session.selectedGraphNodeIDs.count > 1, !draggedNodeUsesFocusPull {
                    let delta = CGPoint(
                        x: moved.x - (nodeDragOrigin?.x ?? moved.x),
                        y: moved.y - (nodeDragOrigin?.y ?? moved.y)
                    )

                    for selectedNodeID in session.selectedGraphNodeIDs {
                        let originalPos = multiNodeDragOrigins[selectedNodeID] ?? graphNodePoint(for: selectedNodeID)
                        let newPos = CGPoint(
                            x: originalPos.x + delta.x,
                            y: originalPos.y + delta.y
                        )
                        session.graphLayout.pin(nodeID: selectedNodeID, at: newPos)
                    }
                } else if draggedNodeUsesFocusPull {
                    pulledGraphPositions[nodeID] = moved
                } else {
                    session.graphLayout.pin(nodeID: nodeID, at: moved)
                }

                layoutRevision &+= 1
            }
            .onEnded { _ in
                if draggedNodeUsesFocusPull, let draggedNodeID {
                    session.graphLayout.pin(nodeID: draggedNodeID, at: graphNodePoint(for: draggedNodeID))
                }
                draggedNodeID = nil
                nodeDragOrigin = nil
                nodeDragPointerOffset = nil
                draggedNodeUsesFocusPull = false
                multiNodeDragOrigins = [:]
                layoutRevision &+= 1
                if !session.showAllGraphTableCards {
                    session.persistCurrentGraphLayout()
                }
            }
    }

    private func graphNodePoint(for nodeID: String) -> CGPoint {
        pulledGraphPositions[nodeID] ?? session.graphLayout.position(for: nodeID)
    }

    private func isFocusRelatedTable(_ nodeID: String) -> Bool {
        guard let target = graphFocusTableRelation else { return false }
        guard nodeID != target.tableID else { return false }
        return relatedNodeIDs(for: target).contains(nodeID)
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
        guard let node = session.graph.node(id: nodeID) else {
            return CGSize(width: 140, height: GraphCardLayout.collapsedHeight)
        }
        return GraphCardLayout.nodeSize(
            title: node.title,
            descriptor: session.descriptor(named: nodeID),
            style: nodeDisplayStyle(for: nodeID, previewColumns: previewColumns(for: nodeID)),
            hovered: hoveredNodeID == nodeID && draggedNodeID == nil
        )
    }






    private func scheduleViewportSessionSync(zoom: CGFloat, pan: CGSize) {
        viewportPublisher.enqueue(GraphViewportTransform(zoom: zoom, pan: pan)) { [session] transform in
            if session.graphZoom != transform.zoom { session.graphZoom = transform.zoom }
            if session.graphPan != transform.pan { session.graphPan = transform.pan }
        }
    }

    private func flushViewportSessionSync() {
        viewportPublisher.flush(GraphViewportTransform(zoom: zoom, pan: pan), force: true) { [session] transform in
            if session.graphZoom != transform.zoom { session.graphZoom = transform.zoom }
            if session.graphPan != transform.pan { session.graphPan = transform.pan }
        }
    }







    private func clearGraphFocusSession(
        animated: Bool = true,
        restoreViewport: Bool = true,
        clearSavedViewport: Bool = true
    ) {
        guard graphFocusTableRelation != nil || tableFocusNodeID != nil || !pulledGraphPositions.isEmpty else { return }
        let savedViewport = preGraphFocusViewport
        let applyClear = {
            pulledGraphPositions.removeAll()
            if tableFocusNodeID != nil || graphFocusTableRelation != nil { session.setExpandedGraphNode(nil) }
            graphFocusTableRelation = nil
            tableFocusNodeID = nil
            tappedRelationTarget = nil
            if clearSavedViewport { preGraphFocusViewport = nil }
        }
        if animated {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { applyClear() }
        } else {
            applyClear()
        }
        if restoreViewport, let savedViewport {
            if let restored = savedViewport.restored(for: presentationMode) {
                setViewport(restored, animated: animated)
            } else {
                refitCurrentScope(in: viewportSize)
            }
        }
    }


    private var graphFocusPlan: GraphFocusPlan? {
        if let target = graphFocusTableRelation {
            return tableRelationFocusPlan(target: target)
        }
        if let nodeID = tableFocusNodeID {
            return GraphFocusPlan(
                activeTableIDs: [nodeID],
                relatedTableIDs: Set(tableConnectionPage(nodeID).ids)
            )
        }
        return nil
    }

    private var effectiveFocusPlan: GraphFocusPlan? {
        let plan = graphFocusPlan
        guard session.graphTableFilter.isActive || session.automationVisibleTableIDs != nil else { return plan }
        let allowed = session.graphVisibleTableIDs
        return GraphFocusPlan(
            activeTableIDs: (plan?.activeTableIDs ?? allowed).intersection(allowed),
            relatedTableIDs: (plan?.relatedTableIDs ?? []).intersection(allowed)
        )
    }



    private func tableRelationFocusPlan(target: GraphRelationHoverTarget) -> GraphFocusPlan {
        let relatedTables = Set(GraphExploration.pageOrdered(relatedNodeIDs(for: target), index: relationPageIndex).ids)
        return GraphFocusPlan(activeTableIDs: [target.tableID], relatedTableIDs: relatedTables)
    }

    private func focusOpacity(for tier: GraphFocusTier?) -> Double {
        switch tier {
        case .related:
            return 0.94
        case .active, .none:
            return 1
        case .hidden:
            return 0
        }
    }

    private func enterGraphFocusSession() {
        if preGraphFocusViewport == nil {
            preGraphFocusViewport = GraphViewportBookmark(transform: GraphViewportTransform(zoom: zoom, pan: pan), presentation: presentationMode)
        }
    }

    private func refitCurrentScope(in size: CGSize) {
        if focusedGroupID != nil, let nodeID = session.selectedGraphNodeID {
            fitTable(nodeID, in: size)
        } else if effectiveFocusPlan != nil {
            fitGraphFocusViewport(in: size)
        } else {
            fitGraph(in: size)
        }
    }

    private func fitGraphFocusViewport(in size: CGSize) {
        guard let plan = effectiveFocusPlan, size != .zero else { return }
        var bounds = CGRect.null
        for tableID in plan.visibleTableIDs() {
            let center = pulledGraphPositions[tableID] ?? session.graphLayout.position(for: tableID)
            let nodeSize = nodeSize(for: tableID)
            let frame = CGRect(x: center.x - nodeSize.width / 2, y: center.y - nodeSize.height / 2,
                               width: nodeSize.width, height: nodeSize.height)
            bounds = bounds.isNull ? frame : bounds.union(frame)
        }
        guard !bounds.isNull else { return }
        let topInset = min(graphControlsHeight + 30, size.height * 0.4)
        let bottomInset: CGFloat = 70
        var transform = GraphViewportTransform.fit(
            contentBounds: bounds,
            in: CGSize(width: size.width, height: max(100, size.height - topInset - bottomInset)),
            padding: 72,
            minZoom: isLargeGraph ? 0.01 : 0.22,
            maxZoom: 1.05
        )
        transform.pan.height += (topInset - bottomInset) / 2
        setViewport(transform, animated: true)
    }

    private func graphFocusSummary(focusPlan: GraphFocusPlan) -> String {
        let tableCount = focusPlan.visibleTableIDs().count
        return "Focus · \(tableCount) \(tableCount == 1 ? "table" : "tables")"
    }







    private func edgePoint(on frame: CGRect, toward target: CGPoint) -> CGPoint {
        let center = frame.center
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }

        let halfWidth = max(frame.width / 2, 1)
        let halfHeight = max(frame.height / 2, 1)
        let scale = min(halfWidth / max(abs(dx), 0.0001), halfHeight / max(abs(dy), 0.0001))
        return CGPoint(
            x: center.x + dx * scale,
            y: center.y + dy * scale
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

    private func clusterBorderColor(for nodeID: String) -> Color? {
        guard shows(.groupColors), let hex = session.clusterColorHex(for: nodeID) else { return nil }
        if let color = scenePreparation.colors[hex] { return color }
        let color = Color(studioHex: hex)
        scenePreparation.colors[hex] = color
        return color
    }

    private func worldFrames(focusPlan: GraphFocusPlan?) -> [String: CGRect] {
        let key = GraphSceneWorldKey(
            graphRevision: renderedGraphRevision, layoutRevision: layoutRevision, presentation: presentationMode,
            hoveredID: hoveredNodeID, draggedID: draggedNodeID, expandedIDs: session.expandedGraphNodeIDs,
            relationTarget: tappedRelationTarget ?? hoveredRelationTarget,
            pulledPositions: pulledGraphPositions, visibleIDs: focusPlan?.visibleTableIDs()
        )
        if scenePreparation.worldKey == key { return scenePreparation.worldFrames }
        let ids = renderedGraph.nodes.compactMap { node in
            focusPlan?.tierForTable(node.id) == .hidden ? nil : node.id
        }
        let frames = GraphInteractionGeometry.worldFrames(
            nodeIDs: ids, positionForNode: graphNodePoint, sizeForNode: nodeSize
        )
        scenePreparation.worldKey = key
        scenePreparation.worldFrames = frames
        scenePreparation.worldRevision &+= 1
        return frames
    }

    private func interactionGeometry(in size: CGSize, focusPlan: GraphFocusPlan?) -> GraphInteractionGeometry {
        let frames = GraphInteractionGeometry.screenFrames(
            worldFrames: worldFrames(focusPlan: focusPlan),
            transform: GraphViewportTransform(zoom: zoom, pan: pan), viewportSize: size
        )
        if scenePreparation.contentWorldRevision != scenePreparation.worldRevision
            || scenePreparation.contentScrollOffsets != cardScrollOffsets {
            scenePreparation.contentWorldRevision = scenePreparation.worldRevision
            scenePreparation.contentScrollOffsets = cardScrollOffsets
            scenePreparation.contentRevision &+= 1
        }
        let retained = Set([draggedNodeID].compactMap { $0 })
        let primary = session.expandedGraphNodeIDs.union(retained)
            .union(usesOverviewMarks ? [] : [hoveredNodeID].compactMap { $0 })
        return interactionGeometryCache.snapshot(
            frames: frames, viewport: CGRect(origin: .zero, size: size), zoom: zoom, isLarge: isLargeGraph || usesOverviewMarks,
            emphasized: session.selectedGraphNodeIDs.union(focusPlan?.visibleTableIDs() ?? []),
            primary: primary, retained: retained, contentRevision: scenePreparation.contentRevision,
            hoveredID: draggedNodeID == nil ? hoveredNodeID : nil,
            connectedIDs: draggedNodeID == nil ? (hoveredNodeID.map { renderedGraph.neighbors(of: $0) } ?? []) : [],
            nodeSizing: session.graphNodeSizeProfile,
            roleForNode: cardRole, descriptorForNode: session.descriptor(named:), displayedColumnsForNode: visibleColumnNames
        )
    }

    /// Prepares the bounded set of relations that carry a travelling signal.
    ///
    /// Track geometry only moves when the scene does, so it is cached against the same
    /// inputs that decide which edges are drawn. The animation itself needs no cache
    /// invalidation: each frame asks `GraphEdgePulseField` where a track's signal is at
    /// that instant.
    private func cachedEdgePulseTracks(
        anchorMap: GraphAnchorMap,
        plan: GraphEdgeLayerPlan,
        geometryRevision: Int
    ) -> [GraphEdgePulseTrack] {
        let key = GraphEdgePulseKey(
            geometryRevision: geometryRevision,
            graphRevision: renderedGraphRevision,
            viewport: viewportSize,
            onlyHighlighted: plan.onlyHighlighted,
            sampleLimit: plan.sampleLimit,
            highlightedEdgeIDs: plan.highlight.highlightedEdgeIDs,
            focusPlan: plan.focusPlan,
            showsAllCards: session.showAllGraphTableCards
        )
        if scenePreparation.pulseKey == key { return scenePreparation.pulseTracks }

        let candidates = visibleEdgeRenders(anchorMap: anchorMap, plan: plan).map { render in
            GraphEdgePulseTrack(
                edgeID: render.edge.id,
                start: render.anchors.source,
                control1: render.control1,
                control2: render.control2,
                end: render.anchors.target,
                isHighlighted: render.isHighlighted
            )
        }
        let tracks = GraphEdgePulseField.select(from: candidates)
        scenePreparation.pulseKey = key
        scenePreparation.pulseTracks = tracks
        return tracks
    }

    private func cachedRelationHighlight(focusNodeID: String?, hoverTarget: GraphRelationHoverTarget?,
                                         edgeLookup: GraphTopologyIndex) -> GraphRelationHighlight {
        let key = GraphSceneHighlightKey(graphRevision: renderedGraphRevision, focusID: focusNodeID, target: hoverTarget)
        if scenePreparation.highlightKey == key, let highlight = scenePreparation.highlight { return highlight }
        let highlight = GraphRelationHighlight(graph: renderedGraph, focusNodeID: focusNodeID,
                                              hoverTarget: hoverTarget, edgeLookup: edgeLookup)
        scenePreparation.highlightKey = key
        scenePreparation.highlight = highlight
        return highlight
    }

    private func graphBoundsAnchorMap() -> GraphAnchorMap {
        let nodeCards = Dictionary(uniqueKeysWithValues: renderedGraph.nodes.map { node in
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
                    role: .collapsedNode,
                    descriptor: nil
                )
            )
        })

        return GraphAnchorMap(nodeCards: nodeCards)
    }

    private func fitGraph(in size: CGSize) {
        if effectiveFocusPlan != nil { fitGraphFocusViewport(in: size); return }
        let bounds = graphContentBoundsForFit()
        let transform: GraphViewportTransform
        let fitMinimumZoom: CGFloat = renderedGraph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 0.005 : 0.45
        let fitPadding: CGFloat = renderedGraph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 72 : 120
        transform = GraphViewportTransform.fit(contentBounds: bounds, in: size, padding: fitPadding, minZoom: fitMinimumZoom)
        setViewport(transform, animated: true)
    }

    private func graphContentBoundsForFit() -> CGRect {
        graphBoundsAnchorMap().contentBounds
    }

    /// Fit every schema on first open. Large schemas use a bounded overview layout and a
    /// lower minimum zoom so their nodes remain reachable instead of opening off-canvas.
    private var shouldAutoFit: Bool {
        true
    }

    private func scheduleInitialViewportFit() {
        initialViewportTask?.cancel()
        initialViewportTask = nil
        guard initialViewport.needsFit, !session.graph.nodes.isEmpty else { return }
        session.initializedGraphViewportDocument = nil
        let request = initialViewport.request
        initialViewportTask = Task { @MainActor in
            // Mounting and presentation changes can propose several pane sizes.
            // Each size change renews the request before its current-size fit.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  initialViewport.canFit(request: request, hasGraph: !session.graph.nodes.isEmpty, size: viewportSize)
            else { return }

            let currentSize = viewportSize
            if session.graphLayout.hasRestoredSnapshot || session.graphLayout.hasSettledLayout {
                if isLargeGraph, let target = graphFocusTableRelation {
                    pullConnectedNodesIntoView(for: target, pageIndex: relationPageIndex)
                } else if isLargeGraph {
                    refitCurrentScope(in: currentSize)
                } else {
                    fitGraph(in: currentSize)
                }
            } else {
                performInitialLayout(in: currentSize)
            }
            initialViewport.didFit(request: request)
            session.initializedGraphViewportDocument = initialViewportDocumentKey
            flushViewportSessionSync()
            initialViewportTask = nil
        }
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

        invalidateClusterTitleCache()

        if refit {
            fitGraph(in: size)
        }
    }

    private func clusterTitleCacheToken(focusPlan: GraphFocusPlan?) -> Int {
        let token = ClusterTitleCacheToken.make(
            layoutRevision: layoutRevision,
            sidecarRevision: clusterTitleCacheKey &+ session.schemaSidecarRevision,
            hasFocusPlan: focusPlan != nil,
            showClusterHalos: shows(.groupTitles)
        )
        return token &* 31 &+ renderedGraphRevision
    }

    private func invalidateClusterTitleCache() {
        clusterTitleCacheKey &+= 1
        clusterTitleCache.cacheKey = -1
        clusterTitleCache.entries = []
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
        } else {
            // Restore the saved compact layout — don't stabilize, just refit
            session.restoreCompactGraphLayoutForCurrentDatabase()
            layoutRevision &+= 1
            // Restore the same zoom/pan instead of fitting
        }
        invalidateClusterTitleCache()
        if isLargeGraph {
            initialViewport.presentationChanged()
            scheduleInitialViewportFit()
        } else {
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
        geometry: GraphInteractionGeometry,
        edgeLookup: GraphTopologyIndex
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

        guard let card = graphCard(at: point, geometry: geometry, edgeLookup: edgeLookup) else {
            if session.showAllGraphTableCards {
                updateViewportHover(nodeID: nil, relationTarget: nil)
            } else {
                withAnimation(.snappy(duration: 0.16)) { hoveredNodeID = nil }
            }
            updateDescriptionHover(nil, for: "")
            scrollTargetCardID = nil
            return
        }

        // Overview and overflow markers have no visible rows. Treating their original
        // expanded card bounds as scrollable would swallow canvas pan gestures.
        if geometry.renderPlan.markerIDs.contains(card.tableID) {
            scrollTargetCardID = nil
            updateDescriptionHover(nil, for: card.tableID)
            updateViewportHover(nodeID: card.tableID, relationTarget: nil)
            return
        }

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
            if let tableDesc = session.tableDescription(for: card.tableID) {
                return DescriptionInfo(column: nil, text: tableDesc)
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

    private func graphCard(at point: CGPoint, geometry: GraphInteractionGeometry,
                           edgeLookup: GraphTopologyIndex) -> GraphCardGeometry? {
        guard let id = geometry.topmostHit(at: point, zIndexForNode: zIndex,
                                          nodeIndexForNode: edgeLookup.nodeIndex(for:)) else { return nil }
        return geometry.anchorMap.nodeCards[id]
    }

    private func relationHoverTarget(
        at point: CGPoint,
        in card: GraphCardGeometry,
        edgeLookup: GraphTopologyIndex
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

    // MARK: - Graph focus layout

    /// Enters table-relation focus: hides unrelated cards, lays out FK/PK neighbors without overlap, and zooms to fit.
    private func pullConnectedNodesIntoView(for target: GraphRelationHoverTarget, pageIndex: Int = 0) {
        guard draggedNodeID == nil else { return }

        let page = GraphExploration.pageOrdered(relatedNodeIDs(for: target), index: pageIndex)
        let connectedIDs = page.ids
        guard !connectedIDs.isEmpty else { return }
        relationPageIndex = page.index

        enterGraphFocusSession()
        graphFocusTableRelation = target
        tableFocusNodeID = nil
        tappedRelationTarget = GraphRelationHoverTarget(
            tableID: target.tableID,
            columnName: target.columnName,
            endpointKind: .column
        )

        let hubCenter = pulledGraphPositions[target.tableID] ?? session.graphLayout.position(for: target.tableID)
        let hubSize = nodeSize(for: target.tableID)
        let items = connectedIDs.map { connectedID in
            GraphFocusRingLayout.Item(id: connectedID, size: nodeSize(for: connectedID))
        }
        var layout = GraphFocusRingLayout.graphPositions(
            hubCenter: hubCenter,
            hubSize: hubSize,
            items: items,
            gap: 88,
            interItemGap: 36
        )

        layout[target.tableID] = hubCenter
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            pulledGraphPositions = layout
        }
        fitGraphFocusViewport(in: viewportSize)
    }

    private func relatedNodeIDs(for target: GraphRelationHoverTarget) -> [String] {
        let key = GraphSceneHighlightKey(graphRevision: renderedGraphRevision, focusID: nil, target: target)
        if scenePreparation.relatedKey == key { return scenePreparation.relatedIDs }
        let index = topologyCache.index(for: renderedGraph, graphRevision: renderedGraphRevision)
        let edges = index.outgoingEdges(for: target.tableID) + index.incomingEdges(for: target.tableID)
        let ids = Array(Set(edges.compactMap { edge in
            if edge.sourceID == target.tableID && edge.sourceColumn == target.columnName {
                return edge.targetID == target.tableID ? nil : edge.targetID
            }
            if edge.targetID == target.tableID && edge.targetColumn == target.columnName {
                return edge.sourceID == target.tableID ? nil : edge.sourceID
            }
            return nil
        })).sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        scenePreparation.relatedKey = key
        scenePreparation.relatedIDs = ids
        return ids
    }

    private func toggleExpandedState(for nodeID: String, in size: CGSize) {
        if tableFocusNodeID == nodeID || graphFocusTableRelation?.tableID == nodeID {
            collapseExpandedNode(nodeID, in: size)
        } else {
            openExpandedNode(nodeID, in: size)
        }
    }

    private func openExpandedNode(_ nodeID: String, in size: CGSize) {
        session.selectGraphNode(nodeID)
        session.setExpandedGraphNode(nodeID)
        focusTableConnections(nodeID)
    }

    private func tableConnectionPage(_ nodeID: String) -> GraphExploration.Page {
        let neighbors = renderedGraph.neighbors(of: nodeID).subtracting([nodeID])
        let allowed = neighbors.intersection(session.graphVisibleTableIDs)
        return GraphExploration.page(Array(allowed), index: relationPageIndex)
    }

    private func focusTableConnections(_ nodeID: String, pageIndex: Int = 0) {
        enterGraphFocusSession()
        relationPageIndex = pageIndex
        tableFocusNodeID = nodeID
        graphFocusTableRelation = nil
        tappedRelationTarget = nil
        hoveredNodeID = nil
        clearRelationHoverState()
        let hubCenter = session.graphLayout.position(for: nodeID)
        let items = tableConnectionPage(nodeID).ids.map { GraphFocusRingLayout.Item(id: $0, size: nodeSize(for: $0)) }
        pulledGraphPositions = GraphFocusRingLayout.graphPositions(hubCenter: hubCenter, hubSize: nodeSize(for: nodeID), items: items)
        layoutRevision &+= 1
        fitGraphFocusViewport(in: viewportSize)
    }

    private func collapseExpandedNode(_ nodeID: String, in size: CGSize) {
        clearGraphFocusSession()
        session.setExpandedGraphNode(nil)
        cardScrollOffsets.removeValue(forKey: nodeID)
        layoutRevision &+= 1
    }

    private func graphFrame(for nodeID: String) -> CGRect? {
        guard session.graph.nodes.contains(where: { $0.id == nodeID }) else { return nil }
        let size = nodeSize(for: nodeID)
        let center = pulledGraphPositions[nodeID] ?? session.graphLayout.position(for: nodeID)
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

    private func applyTrackpadPan(_ delta: CGSize) -> Bool {
        if let targetID = scrollTargetCardID {
            let totalColumns = session.descriptor(named: targetID)?.columns.count ?? 0
            if totalColumns > GraphCardLayout.maxExpandedVisibleRows {
                let maxOffset = CGFloat(totalColumns - GraphCardLayout.maxExpandedVisibleRows) * GraphCardLayout.expandedRowHeight
                let current = cardScrollOffsets[targetID] ?? 0
                // delta.height from scrollWheel: negative = fingers moving up = scroll content up = offset increases.
                let newOffset = max(0, min(maxOffset, current - delta.height / zoom))
                guard newOffset != current else { return false }
                cardScrollOffsets[targetID] = newOffset
                return true
            }
        }
        // IMPORTANT: Natural scrolling - moving fingers right pans viewport right (like moving the canvas)
        // DO NOT change the + signs to - signs - this has been intentionally set for natural scrolling
        let nextPan = CGSize(
            width: pan.width + delta.width,
            height: pan.height + delta.height
        )
        guard nextPan != pan else { return false }
        pan = nextPan
        panStart = pan
        return true
    }

    private func applyTrackpadMagnification(_ magnification: CGFloat, anchor: CGPoint, in size: CGSize) -> Bool {
        let current = GraphViewportTransform(zoom: zoom, pan: pan)
        let next = current.magnified(
            by: magnification, at: anchor, in: size,
            minZoom: isLargeGraph ? 0.005 : 0.12
        )
        guard next != current else { return false }
        zoom = next.zoom
        baseZoom = next.zoom
        pan = next.pan
        panStart = next.pan
        return true
    }
}








private struct GraphNodeCardView<HeaderGesture: Gesture>: View {
    let node: GraphNode
    let descriptor: EditableTableDescriptor?
    let rowCount: Int?
    let tableDescription: String?
    let clusterLabel: String?
    let clusterColor: Color?
    let columnDescription: (String) -> String?
    let previewColumns: [TableColumn]
    let outgoingEdges: [GraphEdge]
    let incomingEdges: [GraphEdge]
    let isSelected: Bool
    let isMultiSelected: Bool
    let viewportZoom: CGFloat
    let displayStyle: GraphNodeCardStyle
    let isFocusRoot: Bool
    let scrollOffset: CGFloat
    let isHovered: Bool
    let isDragging: Bool
    let highlightState: GraphNodeHighlightState
    let keepsTextReadableWhenZoomed: Bool
    let schemaChange: SchemaTableChange?
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
        .background {
            ZStack {
                backgroundShape.fill(backgroundFill)
                let strokeWidth = borderLineWidth
                let strokeColor = isMultiSelected ? StudioPalette.accent : borderColor
                backgroundShape.strokeBorder(strokeColor, lineWidth: strokeWidth)
            }
        }
        .clipShape(backgroundShape)
        .overlay { if let schemaChange { SchemaChangeBorder(change: schemaChange) } }
        .opacity(schemaChange?.kind == .removed ? 0.6 : 1)
        .scaleEffect(isDragging ? 1.012 : 1)
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
            Button(isFocusRoot ? "Return to Overview" : (isExpanded ? "Focus Table" : "Expand Card"), action: toggleExpanded)
            Button("Open Table", action: openTable)
            if schemaChange == nil { Button("Show Top 10", action: showTopRows) }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: displayStyle)
    }

    private var header: some View {
        HStack(spacing: 8) {
            GraphNodeSummary(
                title: node.title, fieldCount: descriptor?.columns.count ?? 0, rowCount: rowCount,
                showsDetailRows: showsDetailRows, hasDescription: tableDescription != nil,
                nameOpacity: nameZoomOpacity, metadataOpacity: metadataZoomOpacity, schemaChange: schemaChange
            )
            .help(node.id)

            if descriptor != nil {
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: isFocusRoot ? "chevron.up" : (isExpanded ? "scope" : "chevron.down"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(StudioPalette.headerSurface.opacity(0.82))
                        )
                }
                .buttonStyle(.plain)
                .help(isFocusRoot ? "Return to overview" : (isExpanded ? "Focus this table" : "Expand card"))
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
            let changeKind = schemaChange?.columnKind(column.name) ?? .unchanged
            Text(changeKind.symbol + (changeKind == .unchanged ? "" : " ") + column.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(changeKind == .unchanged ? StudioPalette.primaryText : changeKind.tint)
                .underline(columnNote != nil, color: StudioPalette.primaryText.opacity(0.4))
                .opacity(columnZoomOpacity)
            Spacer(minLength: 8)
            Text(column.typeLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioPalette.secondaryText)
                .opacity(columnZoomOpacity)
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
        .background {
            let kind = schemaChange?.columnKind(column.name) ?? .unchanged
            if kind != .unchanged { kind.tint.opacity(0.08) }
        }
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

    private var backgroundFill: AnyShapeStyle {
        if let clusterColor, clusterFillOpacity > 0 {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        clusterColor.opacity(clusterFillOpacity),
                        clusterColor.opacity(clusterFillOpacity * 0.74),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
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
        )
    }

    private var clusterFillOpacity: Double {
        guard clusterColor != nil else { return 0 }
        let fillStartZoom: CGFloat = 0.52
        let fullFillZoom: CGFloat = 0.32
        guard viewportZoom < fillStartZoom else { return 0 }
        let zoom = max(min(viewportZoom, fillStartZoom), fullFillZoom)
        let progress = (fillStartZoom - zoom) / (fillStartZoom - fullFillZoom)
        return Double(max(0, min(0.78, progress * 0.78)))
    }

    private var nameZoomOpacity: Double {
        if keepsTextReadableWhenZoomed { return 1 }
        return zoomOpacity(start: 0.82, end: 0.34, minimum: isSelected || isHovered ? 0.72 : 0.38)
    }

    private var metadataZoomOpacity: Double {
        if keepsTextReadableWhenZoomed { return 0.96 }
        return zoomOpacity(start: 0.88, end: 0.42, minimum: 0.8)
    }

    private var columnZoomOpacity: Double {
        if keepsTextReadableWhenZoomed { return 1 }
        return zoomOpacity(start: 0.92, end: 0.48, minimum: isSelected || isHovered ? 0.62 : 0.16)
    }

    private func zoomOpacity(start: CGFloat, end: CGFloat, minimum: Double) -> Double {
        let zoom = max(min(viewportZoom, start), end)
        let progress = (zoom - end) / (start - end)
        return minimum + Double(progress) * (1 - minimum)
    }

    private var borderColor: Color {
        if let clusterColor       { return clusterColor.opacity(isHovered || isSelected ? 1.0 : 0.9) }
        if isHovered                { return Color.black.opacity(0.26) }
        if highlightState != .empty { return Color.black.opacity(0.22) }
        if isSelected               { return Color.black.opacity(0.20) }
        return Color.black.opacity(0.11)
    }

    private var borderLineWidth: CGFloat {
        let zoom = max(viewportZoom, 0.2)
        let zoomOutEmphasis = max(pow(zoom, 1.45), 0.16)
        let filledClusterCap: CGFloat = clusterFillOpacity > 0 ? 9 : .greatestFiniteMagnitude
        if isMultiSelected {
            return min(3.2 / zoomOutEmphasis, filledClusterCap)
        }
        if clusterColor != nil {
            return min((isHovered || isSelected ? 3.0 : 2.5) / zoomOutEmphasis, filledClusterCap)
        }
        return (isSelected || isHovered ? 1.5 : 1.0) / zoomOutEmphasis
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

    init(graph: SchemaGraph, focusNodeID: String?, hoverTarget: GraphRelationHoverTarget? = nil,
         edgeLookup: GraphTopologyIndex? = nil) {
        self.focusNodeID = focusNodeID
        self.hoverTarget = hoverTarget
        let edges: [GraphEdge]
        if let edgeLookup, let tableID = hoverTarget?.tableID ?? focusNodeID {
            edges = edgeLookup.outgoingEdges(for: tableID) + edgeLookup.incomingEdges(for: tableID)
        } else {
            edges = graph.edges
        }

        if let hoverTarget {
            let highlightedEdges = edges.filter { edge in
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

        for edge in edges where edge.sourceID == focusNodeID || edge.targetID == focusNodeID {
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

private struct GraphSceneWorldKey: Equatable {
    let graphRevision: Int
    let layoutRevision: Int
    let presentation: GraphPresentationMode
    let hoveredID: String?
    let draggedID: String?
    let expandedIDs: Set<String>
    let relationTarget: GraphRelationHoverTarget?
    let pulledPositions: [String: CGPoint]
    let visibleIDs: Set<String>?
}

private struct GraphSceneHighlightKey: Equatable {
    let graphRevision: Int
    let focusID: String?
    let target: GraphRelationHoverTarget?
}

/// One relation resolved for the current scene: screen anchors, the Bézier controls the
/// curve is built from, and that curve.
///
/// Carrying the controls rather than recomputing them keeps every consumer on one curve —
/// the stroke, the direction marker, the schema-review change symbol and the travelling
/// pulse. That matters during a schema review, where the two versions of an edited foreign
/// key are deliberately nudged apart.
private struct GraphEdgeRender {
    let edge: GraphEdge
    let anchors: GraphEdgeAnchors
    let control1: CGPoint
    let control2: CGPoint
    let path: Path
    let isHighlighted: Bool
}

private struct GraphEdgePulseKey: Equatable {
    let geometryRevision: Int
    let graphRevision: Int
    let viewport: CGSize
    let onlyHighlighted: Bool
    let sampleLimit: Int?
    let highlightedEdgeIDs: Set<String>
    let focusPlan: GraphFocusPlan?
    let showsAllCards: Bool
}


private struct GraphGroupGeometryKey: Equatable {
    let graphRevision: Int
    let groupingRevision: Int
    let layoutRevision: Int
}

/// Scene preparation is shared by Canvas, cards and native pointer tracking.
/// Mutating these caches does not publish another SwiftUI update.
private final class GraphScenePreparationCache {
    var worldKey: GraphSceneWorldKey?
    var worldFrames: [String: CGRect] = [:]
    var worldRevision = 0
    var contentWorldRevision = -1
    var contentScrollOffsets: [String: CGFloat] = [:]
    var contentRevision = 0
    var colors: [String: Color] = [:]
    var groupGeometryKey: GraphGroupGeometryKey?
    var groupCenters: [String: CGPoint] = [:]
    var highlightKey: GraphSceneHighlightKey?
    var highlight: GraphRelationHighlight?
    var relatedKey: GraphSceneHighlightKey?
    var relatedIDs: [String] = []
    var pulseKey: GraphEdgePulseKey?
    var pulseTracks: [GraphEdgePulseTrack] = []
}

private extension GraphEdge {
    func touches(tableID: String, columnName: String) -> Bool {
        (sourceID == tableID && sourceColumn == columnName)
            || (targetID == tableID && targetColumn == columnName)
    }

    func matches(_ target: GraphRelationHoverTarget) -> Bool {
        switch target.endpointKind {
        case .column:
            return touches(tableID: target.tableID, columnName: target.columnName)
        case .primary:
            return targetID == target.tableID && targetColumn == target.columnName
        case .foreign:
            return sourceID == target.tableID && sourceColumn == target.columnName
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

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}


private struct GraphTrackpadInputSurface: NSViewRepresentable {
    let ignoresInput: Bool
    var geometryRevision: Int = 0
    let onPan: (CGSize) -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void
    let onPointerMove: (CGPoint?) -> Void
    var onInteractionEnded: () -> Void = {}

    func makeNSView(context: Context) -> GraphTrackpadInputView {
        let view = GraphTrackpadInputView()
        view.ignoresInput = ignoresInput
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.onPointerMove = onPointerMove
        view.onInteractionEnded = onInteractionEnded
        view.updateGeometryRevision(geometryRevision)
        return view
    }

    func updateNSView(_ nsView: GraphTrackpadInputView, context: Context) {
        nsView.ignoresInput = ignoresInput
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
        nsView.onPointerMove = onPointerMove
        nsView.onInteractionEnded = onInteractionEnded
        nsView.updateGeometryRevision(geometryRevision)
    }
}

@MainActor
private final class GraphTrackpadInputView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onPointerMove: ((CGPoint?) -> Void)?
    var onInteractionEnded: (() -> Void)?
    var ignoresInput = false {
        didSet {
            guard ignoresInput != oldValue else { return }
            refreshPointerFromWindowLocation()
        }
    }

    private nonisolated(unsafe) var eventMonitor: Any?
    private var trackingAreaReference: NSTrackingArea?
    private let pointerPublisher = GraphInputPublisher<GraphPointerSample>(interval: .milliseconds(16))
    private var geometryRevision = 0
    private var pointerGeometryRevision = 0
    private var hasAcceptedGesture = false

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
        pointerGeometryRevision &+= 1
        refreshTrackingState()
        installMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            pointerPublisher.flush(GraphPointerSample(point: nil, geometryRevision: pointerGeometryRevision)) { [weak self] sample in
                self?.onPointerMove?(sample.point)
            }
            removeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged {
            pointerGeometryRevision &+= 1
            refreshPointerFromWindowLocation()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // .inVisibleRect tracks bounds changes without replacing the area on
        // every SwiftUI render. The local monitor owns mouseMoved delivery.
        guard trackingAreaReference == nil else { return }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
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

    override func mouseExited(with event: NSEvent) {
        publishPointerMove(nil)
        super.mouseExited(with: event)
    }

    func refreshTrackingState() {
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        refreshPointerFromWindowLocation()
    }

    func updateGeometryRevision(_ newRevision: Int) {
        guard geometryRevision != newRevision else { return }
        geometryRevision = newRevision
        pointerGeometryRevision &+= 1
        refreshPointerFromWindowLocation()
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .mouseMoved]) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window, !self.isHiddenOrHasHiddenAncestor
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let isInside = self.bounds.contains(point)

            switch event.type {
            case .scrollWheel:
                guard isInside, !self.ignoresInput else {
                    self.publishInteractionEndIfNeeded(for: event)
                    return event
                }
                // A wheel event can arrive before the coalesced mouse-move sample.
                // Route it using the card actually under this event's pointer.
                self.publishPointerMove(point, immediately: true)
                self.hasAcceptedGesture = true
                if event.hasPreciseScrollingDeltas {
                    self.onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                } else {
                    // Mouse wheel: vertical scroll zooms toward the cursor; horizontal scroll pans.
                    let lineScale: CGFloat = 14
                    let deltaX = event.scrollingDeltaX * lineScale
                    let deltaY = event.scrollingDeltaY * lineScale
                    if abs(deltaY) >= abs(deltaX), deltaY != 0 {
                        self.onMagnify?(-deltaY * 0.09, point)
                    } else if deltaX != 0 {
                        self.onPan?(CGSize(width: deltaX, height: 0))
                    }
                }
                self.publishInteractionEndIfNeeded(for: event)
                return nil
            case .magnify:
                guard isInside, !self.ignoresInput else {
                    self.publishInteractionEndIfNeeded(for: event)
                    return event
                }
                self.publishPointerMove(point, immediately: true)
                self.hasAcceptedGesture = true
                self.onMagnify?(event.magnification, point)
                self.publishInteractionEndIfNeeded(for: event)
                return nil
            case .mouseMoved:
                guard !self.ignoresInput else {
                    self.publishPointerMove(nil)
                    return event
                }
                self.publishPointerMove(isInside ? point : nil)
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

    private func publishInteractionEndIfNeeded(for event: NSEvent) {
        guard hasAcceptedGesture else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            hasAcceptedGesture = false
            onInteractionEnded?()
        }
    }

    private func refreshPointerFromWindowLocation() {
        guard let window, !ignoresInput else {
            publishPointerMove(nil)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        publishPointerMove(bounds.contains(point) ? point : nil)
    }

    private func pointInBounds(for event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) ? point : nil
    }

    private func publishPointerMove(_ point: CGPoint?, immediately: Bool = false) {
        let sample = GraphPointerSample(
            point: ignoresInput ? nil : point,
            geometryRevision: pointerGeometryRevision
        )
        let publish: @MainActor (GraphPointerSample) -> Void = { [weak self] sample in
            self?.onPointerMove?(sample.point)
        }
        if immediately {
            pointerPublisher.flush(sample, publish: publish)
        } else {
            pointerPublisher.enqueue(sample, publish: publish)
        }
    }
}

struct GraphMinimapView: View {
    @Bindable var session: AppSession
    let viewportSize: CGSize
    let zoom: CGFloat
    let pan: CGSize
    let onViewportTap: (CGPoint) -> Void

    /// Build the inset from the same filtered topology as the canvas so hidden
    /// tables cannot remain visible through their incident relations.
    private var visibleGraph: SchemaGraph {
        let visibleIDs = session.graphVisibleTableIDs
        let nodes = session.graph.nodes.filter { visibleIDs.contains($0.id) }
        let edges = session.graph.edges.filter {
            visibleIDs.contains($0.sourceID) && visibleIDs.contains($0.targetID)
        }
        return SchemaGraph(nodes: nodes, edges: edges)
    }


    
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
                
                drawSchemaMinimap(in: &context, size: size, minimapTransform: minimapTransform)
                
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

    private func drawSchemaMinimap(
        in context: inout GraphicsContext,
        size: CGSize,
        minimapTransform: GraphViewportTransform
    ) {
        let graph = visibleGraph
        var edgePath = Path()
        for edge in graph.edges {
            let sourcePos = session.graphLayout.position(for: edge.sourceID)
            let targetPos = session.graphLayout.position(for: edge.targetID)
            let minimapSource = minimapTransform.point(for: sourcePos, in: size)
            let minimapTarget = minimapTransform.point(for: targetPos, in: size)

            edgePath.move(to: minimapSource)
            edgePath.addLine(to: minimapTarget)
        }
        context.stroke(
            edgePath,
            with: .color(StudioPalette.edgeNeutral.opacity(0.3)),
            lineWidth: 0.5
        )

        var nodePath = Path()
        for node in graph.nodes {
            let nodePos = session.graphLayout.position(for: node.id)
            let minimapPos = minimapTransform.point(for: nodePos, in: size)
            let nodeRect = CGRect(
                x: minimapPos.x - 2,
                y: minimapPos.y - 2,
                width: 4,
                height: 4
            )
            nodePath.addPath(Path(roundedRect: nodeRect, cornerRadius: 1))
        }
        context.fill(nodePath, with: .color(StudioPalette.primaryText.opacity(0.6)))
    }

    
    private func graphContentBounds() -> CGRect {
        let padding: CGFloat = 100

        let visibleNodes = visibleGraph.nodes
        guard !visibleNodes.isEmpty else { return .zero }

        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for node in visibleNodes {
            let pos = session.graphLayout.position(for: node.id)
            minX = min(minX, pos.x)
            minY = min(minY, pos.y)
            maxX = max(maxX, pos.x)
            maxY = max(maxY, pos.y)
        }

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

private final class ClusterTitleCache {
    struct Entry {
        let color: Color
        let path: Path
        let label: String?
        let labelAnchor: CGPoint?
    }

    var cacheKey: Int = -1
    var entries: [Entry] = []
}

private final class RelationPreviewCache {
    var isValid = false
    var graphRevision = -1
    var target: GraphRelationHoverTarget?
    var expandedNodeID: String?
    var previews: [String: GraphNodeRelationPreview] = [:]
}

/// Group decorations follow the graph the reader can currently see, while
/// preserving the grouping's stable member order.
enum GraphVisibleGroupMembers {
    static func intersection(_ groupNodeIDs: [String], renderedNodeIDs: Set<String>) -> [String] {
        groupNodeIDs.filter { renderedNodeIDs.contains($0) }
    }

    static func intersection(_ groupNodeIDs: [String], renderedGraph: SchemaGraph) -> [String] {
        intersection(groupNodeIDs, renderedNodeIDs: Set(renderedGraph.nodes.map(\.id)))
    }
}
