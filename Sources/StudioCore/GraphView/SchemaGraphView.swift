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
    @State private var initialViewport = GraphInitialViewport()
    @State private var initialViewportTask: Task<Void, Never>?
    @State private var nodeDragOrigin: CGPoint?
    @State private var nodeDragPointerOffset: CGSize?
    @State private var multiNodeDragOrigins: [String: CGPoint] = [:]
    @State private var draggedNodeID: String?
    @State private var draggedStoryID: String?
    @State private var storyDragOrigin: CGPoint?
    @State private var storyDragPointerOffset: CGSize?
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
    @State private var clusterTitleCache = ClusterTitleCache()
    @State private var descriptionHover: DescriptionHover? = nil
    @State private var cardScrollOffsets: [String: CGFloat] = [:]
    @State private var scrollTargetCardID: String? = nil
    @State private var pulledGraphPositions: [String: CGPoint] = [:]
    @State private var tappedRelationTarget: GraphRelationHoverTarget? = nil
    @State private var isStoriesPresented = false
    @State private var storySearchText = ""
    @State private var isStorySearchCursorActive = false
    @State private var isStoryMenuCardCursorActive = false
    @State private var activeStory: SchemaSidecar.Story?
    @State private var activeStoryPlaybackIndex: Int?
    @State private var selectedStoryID: String?
    @State private var hoveredStoryID: String?
    @State private var storyPopupStoryID: String?
    @State private var storyHighlightedTableIDs: Set<String> = []
    @State private var storyFocusNodeID: String?
    @State private var storyRelationTarget: GraphRelationHoverTarget?
    @State private var storyPlaybackTask: Task<Void, Never>? = nil
    @State private var storySpeechNarrator = StorySpeechNarrator()
    @State private var isStoryPaused = false
    @State private var activeStoryViewportSize: CGSize = .zero
    @State private var pulledStoryGraphPositions: [String: CGPoint] = [:]
    @State private var storyStarModeSourceID: String?
    @State private var graphFocusTableRelation: GraphRelationHoverTarget?
    @State private var draggedStoryUsesStarModePull = false
    @State private var draggedNodeUsesFocusPull = false
    @State private var preGraphFocusViewport: GraphViewportBookmark?
    @State private var preStoryOnlyViewport: GraphViewportBookmark?
    @State private var preStoryShowAllGraphTableCards: Bool?
    @State private var preStoryShowStoryCardsInGraph: Bool?
    @State private var preStoryShowOnlyStoryCardsInGraph: Bool?
    @State private var clusterTitleCacheKey: Int = 0
    @State private var storyGraphCardsCache = StoryGraphCardsCache()
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
    @State private var isNavigatingFromStories = false

    private var isLargeGraph: Bool { session.graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold }
    private var usesOverviewMarks: Bool { isLargeGraph && zoom < GraphExploration.detailZoom }

    public init(session: AppSession) {
        self.session = session
    }

    private var presentationMode: GraphPresentationMode {
        session.showAllGraphTableCards ? .allCards : .compact
    }

    private var initialViewportDocumentKey: String? {
        guard let target = session.databaseTarget else { return nil }
        return "\(target.stableStorageKey)|\(session.databaseURL?.absoluteString ?? "")"
    }

    private var isStoryOnlyMode: Bool {
        session.showStoryCardsInGraph && session.showOnlyStoryCardsInGraph
    }

    private var storyOnlyCardCount: Int {
        StoryGraphPlacement.placeableStoryCount(for: session)
    }

    private var shouldAutoFitStoryViewport: Bool {
        isStoryOnlyMode && storyOnlyCardCount > 0 && storyOnlyCardCount < StoryGraphPlacement.crowdedStoryThreshold
    }

    private var focusNodeID: String? {
        guard !isStoryOnlyMode else { return nil }
        guard hoveredRelationTarget == nil else { return nil }
        if session.showAllGraphTableCards {
            return storyFocusNodeID ?? hoveredNodeID ?? (session.selectedGraphNodeIDs.count <= 1 ? session.selectedGraphNodeID : nil)
        }
        return storyFocusNodeID ?? manuallyExpandedNodeID ?? hoveredNodeID ?? (session.selectedGraphNodeIDs.count <= 1 ? session.selectedGraphNodeID : nil)
    }

    private var manuallyExpandedNodeID: String? {
        session.expandedGraphNodeIDs.sorted().first
    }

    private var relatedPreviewByNode: [String: GraphNodeRelationPreview] {
        guard !session.showAllGraphTableCards else { return [:] }

        let relationTarget = storyRelationTarget ?? tappedRelationTarget ?? hoveredRelationTarget
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
            for edge in session.graph.edges where edge.matches(relationTarget) {
                previews[edge.sourceID, default: .empty].foreignKeyColumns.insert(edge.sourceColumn)
                previews[edge.targetID, default: .empty].primaryKeyColumns.insert(edge.targetColumn)
            }
            return previews
        }

        guard let manuallyExpandedNodeID else { return [:] }

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
                    if activeStory == nil {
                        graphOverlayControls(size: geometry.size)
                    } else {
                        playbackStoryMenuControl(size: geometry.size)
                    }
                }
            }
            .onAppear {
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
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                if initialViewport.viewportChanged() {
                    scheduleInitialViewportFit()
                    return
                }
                guard !session.graph.nodes.isEmpty, newSize.width > 0, newSize.height > 0 else { return }
                if activeStory != nil {
                    activeStoryViewportSize = newSize
                    fitGraphFocusViewport(in: newSize)
                } else if isStoryOnlyMode, shouldAutoFitStoryViewport {
                    fitGraph(in: newSize)
                }
            }
            .onChange(of: session.showOnlyStoryCardsInGraph) { _, _ in
                handleStoryOnlyModeChange(in: geometry.size)
            }
            .onChange(of: storyOnlyCardCount) { _, _ in
                guard isStoryOnlyMode else { return }
                invalidateClusterTitleCache()
                layoutRevision &+= 1
                guard viewportSize != .zero else { return }
                if shouldAutoFitStoryViewport {
                    fitGraph(in: viewportSize)
                }
            }
            .onChange(of: session.maximizedPaneSide) { _, _ in
                guard isStoryOnlyMode, shouldAutoFitStoryViewport, viewportSize != .zero else { return }
                fitGraph(in: viewportSize)
            }
            .onChange(of: session.graphRevision) { _, _ in
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
                if let focusedGroupID, session.graphGrouping.group(id: focusedGroupID) == nil {
                    self.focusedGroupID = nil
                    focusedGroupPage = 0
                    overviewViewport = nil
                    fitGraph(in: geometry.size)
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
                scheduleViewportSessionSync(zoom: newZoom, pan: pan)
            }
            .onChange(of: pan) { _, newPan in
                scheduleViewportSessionSync(zoom: zoom, pan: newPan)
            }
            .onChange(of: session.storyPlaybackCommand?.id) { _, _ in
                guard let command = session.storyPlaybackCommand else { return }
                handleStoryPlaybackCommand(command.kind)
            }
            .onDisappear {
                initialViewportTask?.cancel()
                initialViewportTask = nil
                initialViewport.cancel()
                flushViewportSessionSync()
                storyPlaybackTask?.cancel()
                storyPlaybackTask = nil
                storySpeechNarrator.stop()
                updateReadAloudStatus(.idle)
                preStoryShowAllGraphTableCards = nil
                preStoryShowStoryCardsInGraph = nil
                preStoryShowOnlyStoryCardsInGraph = nil
                session.storyPlaybackOverlay = nil
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
        let renderPlan = geometry.renderPlan
        let edgeLookup = topologyCache.index(for: session.graph, graphRevision: session.graphRevision)
        let currentFocusNodeID = focusNodeID
        let currentHoverTarget = storyRelationTarget ?? tappedRelationTarget ?? hoveredRelationTarget
        let relationHighlight = cachedRelationHighlight(focusNodeID: currentFocusNodeID,
                                                      hoverTarget: currentHoverTarget, edgeLookup: edgeLookup)
        let renderedNodes = isStoryOnlyMode ? [] : session.graph.nodes.filter { renderPlan.detailIDs.contains($0.id) }
        let storyCards = cachedStoryGraphCards()
        let visibleStoryCards = focusPlan.map { plan in
            storyCards.filter { plan.tierForStory($0.id) != .hidden }
        } ?? storyCards
        let emphasizedStoryTableIDs = emphasizedStoryTableIDs(for: storyCards, focusPlan: focusPlan)
        let selectedRelatedStoryIDs = storyStarHubID.map { relatedStoryIDs(for: $0, in: storyCards) } ?? []
        let _ = layoutRevision

        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(backgroundPanGesture)
                .onTapGesture { point in
                    if !isStoryOnlyMode,
                       let card = graphCard(at: point, geometry: geometry, edgeLookup: edgeLookup),
                       renderPlan.markerIDs.contains(card.tableID) {
                        revealTable(card.tableID, in: size)
                        return
                    }
                    if storyPopupStoryID != nil {
                        withAnimation(.snappy(duration: 0.18)) {
                            storyPopupStoryID = nil
                        }
                        return
                    }
                    if storyStarModeSourceID != nil || graphFocusTableRelation != nil
                        || !pulledGraphPositions.isEmpty || !pulledStoryGraphPositions.isEmpty {
                        clearGraphFocusSession()
                    }
                    if let expandedID = manuallyExpandedNodeID {
                        toggleExpandedState(for: expandedID, in: viewportSize)
                    }
                    selectedStoryID = nil
                    hoveredStoryID = nil
                    session.clearGraphSelection()
                    withAnimation(.snappy(duration: 0.18)) {
                        isFeaturesOpen = false
                    }
                }

            GraphTrackpadInputSurface(
                ignoresInput: isStoriesPresented || storyPopupStoryID != nil,
                geometryRevision: geometry.revision,
                onPan: { delta in
                    applyTrackpadPan(delta)
                },
                onMagnify: { magnification, anchor in
                    applyTrackpadMagnification(magnification, anchor: anchor, in: size)
                },
                onPointerMove: { point in
                    if isStoryOnlyMode {
                        handleViewportPointerMove(nil, geometry: geometry, edgeLookup: edgeLookup)
                    } else {
                        handleViewportPointerMove(point, geometry: geometry, edgeLookup: edgeLookup)
                    }
                },
                onInteractionEnded: { flushViewportSessionSync() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            Canvas { context, canvasSize in
                drawClusterTitles(in: &context, canvasSize: canvasSize)
            }
            .allowsHitTesting(false)

            if !isStoryOnlyMode {
                Canvas { context, _ in
                    if usesOverviewMarks, focusPlan == nil {
                        drawGroupConnections(in: &context, size: size)
                    } else {
                        drawEdges(in: &context, anchorMap: anchorMap, relationHighlight: relationHighlight, focusPlan: focusPlan)
                    }
                    drawOverviewMarks(in: &context, anchorMap: anchorMap, nodeIDs: renderPlan.markerIDs)
                }
                .allowsHitTesting(false)
            }

            if !storyCards.isEmpty {
                Canvas { context, _ in
                    drawStoryGraphEdges(
                        in: &context,
                        storyCards: visibleStoryCards,
                        anchorMap: anchorMap,
                        viewportSize: size,
                        showsTableLinks: !isStoryOnlyMode,
                        focusPlan: focusPlan
                    )
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
                    scrollOffset: scrollOffset,
                    isHovered: hoveredNodeID == node.id,
                    isDragging: draggedNodeID == node.id,
                    isStoryHighlighted: storyHighlightedTableIDs.contains(node.id) || emphasizedStoryTableIDs.contains(node.id),
                    highlightState: relationHighlight.highlightState(for: node.id),
                    keepsTextReadableWhenZoomed: focusPlan != nil,
                    selectNode: {
                        clearGraphFocusSession()
                        selectedStoryID = nil
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
                .opacity(focusOpacity(for: focusPlan?.tierForTable(node.id)))
                .shadow(
                    color: StudioPalette.shadow.opacity(session.showAllGraphTableCards ? 0.38 : 0.8),
                    radius: shadowRadius(for: node.id),
                    y: session.showAllGraphTableCards ? 5 : (draggedNodeID == node.id ? 16 : 10)
                )
                .zIndex(zIndex(for: node.id))
            }

            ForEach(visibleStoryCards) { card in
                let storyFocusTier = focusPlan?.tierForStory(card.id)
                let isEmphasized = storyIsEmphasized(card.id)
                StorySchemaCardView(
                    story: card.story,
                    clusterLabel: card.clusterLabel,
                    clusterColor: card.clusterColor,
                    tableCount: card.tableIDs.count,
                    relationCount: card.story.relatedStories.count,
                    isActive: activeStory?.id == card.story.id,
                    isSelected: storyStarHubID == card.story.id,
                    isHovered: hoveredStoryID == card.story.id,
                    isDragging: draggedStoryID == card.story.id,
                    isConnected: selectedRelatedStoryIDs.contains(card.story.id),
                    allowHoverEffects: !isViewportPanning,
                    selectStory: {
                        selectStory(card.story)
                    },
                    startStory: {
                        selectedStoryID = card.story.id
                        startStory(card.story, in: size)
                    },
                    pullConnections: {
                        selectStory(card.story)
                        pullStoryConnectionsIntoView(for: card)
                    },
                    hoverChanged: { isHovered in
                        guard !isViewportPanning else { return }
                        hoveredStoryID = isHovered ? card.story.id : nil
                    },
                    openDetail: {
                        withAnimation(.snappy(duration: 0.18)) {
                            storyPopupStoryID = card.story.id
                        }
                    }
                )
                .frame(width: StoryGraphCardLayout.width, height: StoryGraphCardLayout.height, alignment: .topLeading)
                .scaleEffect(zoom)
                .position(storyScreenCenter(for: card, in: size))
                .opacity(focusOpacity(for: storyFocusTier))
                .simultaneousGesture(storyDragGesture(storyID: card.id, in: size))
                .shadow(
                    color: StudioPalette.shadow.opacity(isEmphasized || draggedStoryID == card.id ? 0.52 : 0.22),
                    radius: draggedStoryID == card.id ? 14 : (isEmphasized ? 10 : 4),
                    y: draggedStoryID == card.id ? 8 : (isEmphasized ? 6 : 2)
                )
                .zIndex(draggedStoryID == card.id ? 6 : (isEmphasized ? 5 : (selectedRelatedStoryIDs.contains(card.id) ? 3 : 1.5)))
            }
            .compositingGroup()
            
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

            if activeStory == nil, let focusPlan = graphFocusPlan, focusPlan.isActive {
                graphFocusBanner(focusPlan: focusPlan)
                    .zIndex(1100)
            }

            if let popupStoryID = storyPopupStoryID,
               let popupStory = session.stories.first(where: { $0.id == popupStoryID }) {
                storyCardPopup(for: popupStory, in: size)
                    .zIndex(1300)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .coordinateSpace(name: "graphViewport")
        .animation(session.showAllGraphTableCards ? nil : .snappy(duration: 0.18), value: session.expandedGraphNodeIDs)
        .animation(.snappy(duration: 0.18), value: session.showAllGraphTableCards)
    }

    @ViewBuilder
    private func graphScopeControls(in size: CGSize) -> some View {
        if let group = session.graphGrouping.group(id: focusedGroupID ?? "") {
            let page = GraphExploration.pageOrdered(group.nodeIDs, index: focusedGroupPage)
            HStack(spacing: 8) {
                Button { showGraphOverview(in: size) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Return to all groups")
                Text(group.label).lineLimit(1).help(group.label)
                if page.count > 1 {
                    Button { focusGroup(group.id, pageIndex: page.index - 1, in: size) } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(page.index == 0).help("Previous tables in group")
                    Text("\(page.start)–\(page.end) of \(page.total)").monospacedDigit()
                    Button { focusGroup(group.id, pageIndex: page.index + 1, in: size) } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(page.index + 1 == page.count).help("Next tables in group")
                } else {
                    Text("\(page.total) tables").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
        } else {
            Text("\(session.graph.nodes.count) tables · \(session.graphGrouping.groupCount) groups")
                .font(.caption).foregroundStyle(.secondary)
        }
        if usesOverviewMarks {
            Text("Select a table, find a group, or zoom in for detail")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func focusGroup(_ groupID: String, pageIndex: Int = 0, in size: CGSize) {
        guard let group = session.graphGrouping.group(id: groupID) else { return }
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
        fitGraphFocusViewport(in: size)
    }

    private func showGraphOverview(in size: CGSize) {
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
        prepareTableNavigation()
        rememberOverviewViewport()
        clearGraphFocusSession(restoreViewport: false)
        focusedGroupID = session.graphGrouping.nodeToGroup[nodeID]
        if let group = session.graphGrouping.group(for: nodeID) {
            let ids = group.nodeIDs
            focusedGroupPage = (ids.firstIndex(of: nodeID) ?? 0) / GraphExploration.pageSize
        }
        session.selectGraphNode(nodeID)
        session.setExpandedGraphNode(nodeID)
        hoveredNodeID = nil
        clearRelationHoverState()
        isGraphNavigatorPresented = false
        invalidateClusterTitleCache()
        fitTable(nodeID, in: size)
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
        if session.showOnlyStoryCardsInGraph {
            if overviewViewport == nil {
                overviewViewport = preStoryOnlyViewport
            }
            isNavigatingFromStories = true
            preStoryOnlyViewport = nil
            session.showOnlyStoryCardsInGraph = false
        }
        selectedStoryID = nil
        storyPopupStoryID = nil
    }

    private func drawOverviewMarks(in context: inout GraphicsContext, anchorMap: GraphAnchorMap, nodeIDs: Set<String>) {
        for id in nodeIDs {
            guard let frame = anchorMap.nodeCards[id]?.frame else { continue }
            let color = clusterBorderColor(for: id) ?? StudioPalette.accent
            let mark = GraphExploration.markerFrame(for: frame)
            context.fill(Path(roundedRect: mark, cornerRadius: min(4, mark.height / 2)), with: .color(color.opacity(0.62)))
            if session.selectedGraphNodeIDs.contains(id) {
                context.stroke(Path(roundedRect: mark, cornerRadius: min(4, mark.height / 2)),
                               with: .color(StudioPalette.primaryText), lineWidth: 1.5)
            }
        }
    }

    private func drawGroupConnections(in context: inout GraphicsContext, size: CGSize) {
        let key = GraphGroupGeometryKey(graphRevision: session.graphRevision,
                                        groupingRevision: session.graphGroupingRevision, layoutRevision: layoutRevision)
        if scenePreparation.groupGeometryKey != key {
            var centers: [String: CGPoint] = [:]
            for group in session.graphGrouping.groups where !group.nodeIDs.isEmpty {
                let sum = group.nodeIDs.reduce(CGPoint.zero) { sum, id in
                    let point = session.graphLayout.position(for: id)
                    return CGPoint(x: sum.x + point.x, y: sum.y + point.y)
                }
                centers[group.id] = CGPoint(x: sum.x / CGFloat(group.nodeIDs.count), y: sum.y / CGFloat(group.nodeIDs.count))
            }
            scenePreparation.groupGeometryKey = key
            scenePreparation.groupCenters = centers
        }
        let transform = GraphViewportTransform(zoom: zoom, pan: pan)
        let centers = scenePreparation.groupCenters.mapValues { transform.point(for: $0, in: size) }
        let links = topologyCache.groupLinks(for: session.graph, graphRevision: session.graphRevision,
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
        guard session.showClusterHalos || isStoryOnlyMode || focusPlan != nil else { return }

        let titleStyle = StoryGraphPlacement.clusterTitleStyle(for: session)
        let playbackKey = (activeStoryPlaybackIndex ?? -1) &* 31
        let cacheKey = clusterTitleCacheToken(focusPlan: focusPlan, playbackKey: playbackKey)

        if clusterTitleCache.cacheKey != cacheKey {
            if let focusPlan {
                clusterTitleCache.entries = focusClusterTitleEntries(focusPlan: focusPlan, padding: titleStyle.padding)
            } else if isStoryOnlyMode {
                clusterTitleCache.entries = storyClusterTitleEntries(padding: titleStyle.padding)
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
                    .foregroundStyle(entry.color.opacity(inFocusLayout ? 0.96 : 0.85))
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
        let schemas = Set(session.tables.compactMap(\.schemaName))
        return session.graphGrouping.groups.compactMap { group in
            guard let color = Color(studioHex: group.colorHex) else { return nil }
            let frames = group.nodeIDs.compactMap { name -> CGRect? in
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
            return makeFocusClusterTitleEntry(color: color, label: "\(label) · \(group.nodeIDs.count)",
                                              frames: frames, padding: pad, labelGap: 30)
        }
    }

    private func focusClusterTitleEntries(focusPlan: GraphFocusPlan, padding pad: CGFloat) -> [ClusterTitleCache.Entry] {
        var entries: [ClusterTitleCache.Entry] = []
        let labelGap: CGFloat = 30

        for cluster in session.graphGrouping.groups {
            guard let color = Color(studioHex: cluster.colorHex) else { continue }
            let frames = cluster.nodeIDs.compactMap { name -> CGRect? in
                guard session.graph.contains(nodeID: name) else { return nil }
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

        let visibleStories = storyGraphCards().filter { focusPlan.tierForStory($0.id) != .hidden }
        let grouped = Dictionary(grouping: visibleStories, by: \.clusterKey)
        for clusterKey in grouped.keys.sorted() {
            let cards = grouped[clusterKey] ?? []
            guard let sample = cards.first else { continue }
            let color = Color(studioHex: sample.clusterColorHex ?? "")
                ?? sample.clusterColor
                ?? StudioPalette.accent
            let frames = cards.map { card -> CGRect in
                let center = storyGraphPoint(for: card)
                return CGRect(
                    x: center.x - StoryGraphCardLayout.width / 2,
                    y: center.y - StoryGraphCardLayout.height / 2,
                    width: StoryGraphCardLayout.width,
                    height: StoryGraphCardLayout.height
                )
            }
            entries.append(
                makeFocusClusterTitleEntry(
                    color: color,
                    label: sample.clusterLabel ?? clusterKey,
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

    private func storyClusterTitleEntries(padding pad: CGFloat, focusPlan: GraphFocusPlan? = nil) -> [ClusterTitleCache.Entry] {
        let cards = storyGraphCards().filter { card in
            guard let focusPlan else { return true }
            return focusPlan.tierForStory(card.id) != .hidden
        }
        guard !cards.isEmpty else { return [] }

        let grouped = Dictionary(grouping: cards, by: \.clusterKey)
        return grouped.keys.sorted().compactMap { clusterKey in
            let clusterCards = grouped[clusterKey] ?? []
            guard let sample = clusterCards.first else { return nil }
            let color = Color(studioHex: sample.clusterColorHex ?? "")
                ?? sample.clusterColor
                ?? StudioPalette.accent
            var merged: Path? = nil
            for card in clusterCards {
                let point = storyGraphPoint(for: card)
                let halfWidth = StoryGraphCardLayout.width / 2 + pad
                let halfHeight = StoryGraphCardLayout.height / 2 + pad
                let rect = CGRect(
                    x: point.x - halfWidth,
                    y: point.y - halfHeight,
                    width: halfWidth * 2,
                    height: halfHeight * 2
                )
                let bubble = Path(roundedRect: rect, cornerRadius: halfHeight)
                merged = merged.map { $0.union(bubble) } ?? bubble
            }
            guard let path = merged else { return nil }
            let label = clusterCards.first?.clusterLabel ?? clusterKey
            return ClusterTitleCache.Entry(color: color, path: path, label: label, labelAnchor: nil)
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

    private func drawStoryGraphEdges(
        in context: inout GraphicsContext,
        storyCards: [StoryGraphCard],
        anchorMap: GraphAnchorMap,
        viewportSize: CGSize,
        showsTableLinks: Bool,
        focusPlan: GraphFocusPlan? = nil
    ) {
        let storyCardsByID = Dictionary(uniqueKeysWithValues: storyCards.map { ($0.id, $0) })
        let selectedRelatedStoryIDs = storyStarHubID.map { relatedStoryIDs(for: $0, in: storyCards) } ?? []

        for card in storyCards {
            let isEmphasized = storyIsEmphasized(card.id)
            let sourceFrame = storyFrame(for: card, in: viewportSize)
            if showsTableLinks {
                let tableIDs = isEmphasized ? card.tableIDs : card.primaryTableIDs

                for tableID in tableIDs.prefix(tableLinkLimit(isEmphasized: isEmphasized)) {
                    if let focusPlan, focusPlan.tierForTable(tableID) == .hidden { continue }
                    guard let tableFrame = anchorMap.nodeCards[tableID]?.frame else { continue }
                    let start = edgePoint(on: sourceFrame, toward: tableFrame.center)
                    let end = edgePoint(on: tableFrame, toward: sourceFrame.center)
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(
                        path,
                        with: .color(
                            card.clusterColor?.opacity(isEmphasized ? 0.52 : 0.22)
                                ?? StudioPalette.edgeNeutral.opacity(isEmphasized ? 0.36 : 0.16)
                        ),
                        style: StrokeStyle(
                            lineWidth: isEmphasized ? 1.4 : 0.9,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: isEmphasized ? [5, 5] : [3, 7]
                        )
                    )
                }
            }

            for relation in card.story.relatedStories {
                guard let targetCard = storyCardsByID[relation.storyID] else { continue }
                if let focusPlan {
                    if focusPlan.tierForStory(card.id) == .hidden || focusPlan.tierForStory(targetCard.id) == .hidden {
                        continue
                    }
                }
                let targetFrame = storyFrame(for: targetCard, in: viewportSize)
                let direction = storyRelationDirection(for: relation.kind)
                let drawsTowardTarget = direction != .targetToSource
                let startFrame = drawsTowardTarget ? sourceFrame : targetFrame
                let endFrame = drawsTowardTarget ? targetFrame : sourceFrame
                let start = edgePoint(on: startFrame, toward: endFrame.center)
                let end = edgePoint(on: endFrame, toward: startFrame.center)
                let relationIsEmphasized = isEmphasized
                    || storyIsEmphasized(targetCard.id)
                    || selectedRelatedStoryIDs.contains(card.id)
                    || selectedRelatedStoryIDs.contains(targetCard.id)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(
                    path,
                    with: .color(StudioPalette.primaryText.opacity(relationIsEmphasized ? 0.34 : 0.14)),
                    style: StrokeStyle(
                        lineWidth: relationIsEmphasized ? 1.25 : 0.8,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [2, 5]
                    )
                )
                if relationIsEmphasized, direction != .none {
                    drawStoryRelationMarker(in: &context, from: start, to: end)
                }
                if shouldShowStoryRelationLabel(
                    between: card.id,
                    and: targetCard.id,
                    relationHighlighted: relationIsEmphasized
                ) {
                    drawStoryRelationLabel(
                        in: &context,
                        title: storyRelationDisplayName(relation.kind),
                        at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
                        emphasized: relationIsEmphasized
                    )
                }
            }
        }
    }

    private func tableLinkLimit(isEmphasized: Bool) -> Int {
        if isEmphasized { return 12 }
        if zoom < 0.55 { return 1 }
        if zoom < 0.85 { return 2 }
        return 3
    }

    private func shouldShowStoryRelationLabel(
        between sourceID: String,
        and targetID: String,
        relationHighlighted: Bool
    ) -> Bool {
        if hoveredStoryID == sourceID || hoveredStoryID == targetID {
            return true
        }
        if activeStory?.id == sourceID || activeStory?.id == targetID {
            return true
        }
        if storyStarModeSourceID != nil, relationHighlighted {
            return true
        }
        if let focusPlan = effectiveFocusPlan, focusPlan.isActive,
           focusPlan.tierForStory(sourceID) != .hidden,
           focusPlan.tierForStory(targetID) != .hidden {
            return true
        }
        return false
    }

    private func drawStoryRelationMarker(in context: inout GraphicsContext, from start: CGPoint, to end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx != 0 || dy != 0 else { return }

        let angle = atan2(dy, dx)
        let markerCenter = CGPoint(x: start.x + dx * 0.72, y: start.y + dy * 0.72)
        let markerSize: CGFloat = 4.2
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
            with: .color(StudioPalette.primaryText.opacity(0.42)),
            style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawStoryRelationLabel(
        in context: inout GraphicsContext,
        title: String,
        at point: CGPoint,
        emphasized: Bool
    ) {
        let labelFont = Font.system(size: 10, weight: .bold)
        let strokeOffsets: [(CGFloat, CGFloat)] = [
            (-1.4, -1.4), (0, -1.4), (1.4, -1.4),
            (-1.4, 0),                 (1.4, 0),
            (-1.4, 1.4),  (0, 1.4),   (1.4, 1.4),
        ]

        for (dx, dy) in strokeOffsets {
            context.draw(
                Text(title)
                    .font(labelFont)
                    .foregroundStyle(Color.white.opacity(emphasized ? 0.94 : 0.78)),
                at: CGPoint(x: point.x + dx, y: point.y + dy),
                anchor: .center
            )
        }

        context.draw(
            Text(title)
                .font(labelFont)
                .foregroundStyle(StudioPalette.secondaryText.opacity(emphasized ? 0.98 : 0.72)),
            at: point,
            anchor: .center
        )
    }

    private func drawEdges(
        in context: inout GraphicsContext,
        anchorMap: GraphAnchorMap,
        relationHighlight: GraphRelationHighlight,
        focusPlan: GraphFocusPlan? = nil
    ) {
        for edge in session.graph.edges {
            if let focusPlan {
                let sourceVisible = focusPlan.tierForTable(edge.sourceID) != .hidden
                let targetVisible = focusPlan.tierForTable(edge.targetID) != .hidden
                guard sourceVisible, targetVisible else { continue }
            }
            guard let anchors = anchorMap.edgeAnchors(for: edge) else { continue }

            let isHighlighted = relationHighlight.highlightedEdgeIDs.contains(edge.id)
            let path = edgePath(from: anchors.source, to: anchors.target)
            guard path.boundingRect.insetBy(dx: -8, dy: -8).intersects(CGRect(origin: .zero, size: viewportSize)) else { continue }
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
                    Button {
                        isGraphNavigatorPresented.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .help("Find any table or group")
                    .accessibilityLabel("Find tables and groups")
                    .popover(isPresented: $isGraphNavigatorPresented) {
                        GraphNavigatorView(
                            graph: session.graph, grouping: session.graphGrouping,
                            onGroup: { focusGroup($0, in: size) },
                            onTable: { revealTable($0, in: size) },
                            onOverview: { showGraphOverview(in: size) }
                        )
                    }
                    // Features button with flyout menu
                    FeaturesMenuButton(
                        isOpen: $isFeaturesOpen,
                        showCardinals: $showCardinals,
                        showClusterHalos: Binding(
                            get: { session.showClusterHalos },
                            set: { session.showClusterHalos = $0 }
                        ),
                        hasClusters: !session.graphGrouping.groups.isEmpty,
                        storyCount: session.schemaSidecar.stories.count,
                        onOpenStories: {
                            session.reloadSchemaSidecarFromDisk()
                            withAnimation(.snappy(duration: 0.2)) {
                                isStoriesPresented.toggle()
                                isFeaturesOpen = false
                            }
                        }
                    )

                    Button {
                        // Pick up any edits to the sidecar and wipe the cached layout so
                        // stale positions from earlier app builds can't get restored on
                        // top of fresh cluster geometry.
                        session.reloadSchemaSidecarFromDisk()
                        session.clearPersistedGraphLayout()
                        session.clearPersistedStoryGraphLayout()
                        pulledStoryGraphPositions.removeAll()
                        invalidateClusterTitleCache()
                        rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
                    } label: {
                        Label("Relayout", systemImage: "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(StudioPalette.accent)
                    .help("Reload sidecar notes and cluster hints, then rebuild the layout")
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
                .help("Expand table cards; zoom in to read individual columns")

                graphScopeControls(in: size)
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

            if isStoriesPresented {
                storiesPanel(in: size)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                    .zIndex(1200)
            }

        }
    }

    private func playbackStoryMenuControl(size: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isStoriesPresented.toggle()
                }
            } label: {
                Image(systemName: "book.pages")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isStoriesPresented ? Color.white : StudioPalette.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(
                        isStoriesPresented ? StudioPalette.accent : StudioPalette.chromeFillStrong,
                        in: Circle()
                    )
                    .overlay {
                        Circle()
                            .stroke(StudioPalette.border, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Show stories")
            .onHover { isHovered in
                guard isHovered else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    isStoriesPresented = true
                }
            }
            .padding(.top, 18)
            .padding(.trailing, 18)

            if isStoriesPresented {
                storiesPanel(in: size)
                    .padding(.top, 62)
                    .padding(.trailing, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                    .zIndex(1200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(1200)
    }

    private func storiesPanel(in size: CGSize) -> some View {
        let width = min(max(size.width * 0.44, 400), 540)
        let rows = storyMenuRows()
        let filteredRows = filteredStoryMenuRows(rows)
        let query = normalizedStorySearchText

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Stories", systemImage: "book.pages")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)

                Spacer()

                if !rows.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            let isShowing = !session.showStoryCardsInGraph
                            session.showStoryCardsInGraph = isShowing
                            if !isShowing {
                                selectedStoryID = nil
                                hoveredStoryID = nil
                                clearGraphFocusSession(animated: false)
                                session.showOnlyStoryCardsInGraph = false
                            }
                        }
                        if session.showStoryCardsInGraph {
                            fitGraph(in: size)
                        }
                    } label: {
                        Image(systemName: session.showStoryCardsInGraph ? "rectangle.3.group.fill" : "rectangle.3.group")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(session.showStoryCardsInGraph ? StudioPalette.accent : StudioPalette.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(session.showStoryCardsInGraph ? "Hide story cards in schema" : "Show story cards in schema")

                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            let isShowingOnlyStories = !session.showOnlyStoryCardsInGraph
                            session.showOnlyStoryCardsInGraph = isShowingOnlyStories
                            if isShowingOnlyStories {
                                session.showStoryCardsInGraph = true
                                session.clearGraphSelection()
                                session.setExpandedGraphNode(nil)
                                pulledGraphPositions.removeAll()
                                tappedRelationTarget = nil
                            }
                        }
                    } label: {
                        Image(systemName: session.showOnlyStoryCardsInGraph ? "eye.slash.fill" : "eye.slash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(session.showOnlyStoryCardsInGraph ? StudioPalette.accent : StudioPalette.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(session.showOnlyStoryCardsInGraph ? "Show schema nodes with stories" : "Show only stories")
                }

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isStoriesPresented = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close stories")
            }

            storySearchField

            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No stories in this sidecar.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StudioPalette.primaryText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioPalette.gridSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(StudioPalette.borderSoft)
                }
            } else if filteredRows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No matching stories.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StudioPalette.primaryText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioPalette.gridSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(StudioPalette.borderSoft)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filteredRows) { row in
                            storyRow(row, viewportSize: size, searchQuery: query)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: min(420, max(220, size.height - 190)))
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(StudioPalette.chromeFillStrong)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(StudioPalette.border, lineWidth: 1)
        }
        .shadow(color: StudioPalette.shadow.opacity(0.8), radius: 24, y: 14)
    }

    private var storySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioPalette.tertiaryText)

            TextField("Search title, date, or cluster", text: $storySearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioPalette.primaryText)

            if !normalizedStorySearchText.isEmpty {
                Button {
                    storySearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioPalette.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(StudioPalette.headerSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StudioPalette.borderSoft, lineWidth: 1)
        }
        .onHover { setStorySearchCursorActive($0) }
        .onDisappear { setStorySearchCursorActive(false) }
    }

    private var normalizedStorySearchText: String {
        storySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func storyMenuRows() -> [StoryMenuRow] {
        session.stories.map { story in
            let cluster = session.schemaSidecar.primaryClusterCoverage(for: story)
            return StoryMenuRow(
                story: story,
                dateText: compactCreatedAt(story.createdAt),
                rawDateText: story.createdAt,
                clusterLabel: cluster?.displayLabel ?? "Schema",
                clusterColor: cluster?.color.flatMap { Color(studioHex: $0) } ?? StudioPalette.accentSoft
            )
        }
    }

    private func filteredStoryMenuRows(_ rows: [StoryMenuRow]) -> [StoryMenuRow] {
        let query = normalizedStorySearchText
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.story.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || row.dateText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || row.rawDateText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || row.clusterLabel.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    @ViewBuilder
    private func storyDetailScrollContent(_ story: SchemaSidecar.Story) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StoryUserCardFormatView(
                actor: story.actor,
                goal: story.goal,
                benefit: story.benefit,
                fallbackText: story.userStoryText,
                conversation: story.conversation,
                acceptanceCriteria: story.acceptanceCriteria.map(\.displayText)
            )

            if !story.playback.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Playback")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioPalette.tertiaryText)

                    ForEach(Array(story.playback.enumerated()), id: \.offset) { index, beat in
                        Text("\(index + 1). \(beat.text)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(StudioPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storyCardPopup(for story: SchemaSidecar.Story, in viewportSize: CGSize) -> some View {
        let width = min(max(viewportSize.width * 0.38, 320), 440)
        let maxScrollHeight = min(viewportSize.height * 0.62, 480)

        return ZStack {
            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.18)) {
                        storyPopupStoryID = nil
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(story.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudioPalette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        if let userStoryText = story.userStoryText {
                            Text(userStoryText)
                                .font(.caption)
                                .foregroundStyle(StudioPalette.primaryText.opacity(0.74))
                                .lineLimit(2)
                        }

                        HStack(spacing: 8) {
                            Text(compactCreatedAt(story.createdAt))
                            Text("\(story.playback.count) \(story.playback.count == 1 ? "beat" : "beats")")
                            if !story.acceptanceCriteria.isEmpty {
                                Text("\(story.acceptanceCriteria.count) AC")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(StudioPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            storyPopupStoryID = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(StudioPalette.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }

                Divider().opacity(0.55)

                ScrollView(.vertical, showsIndicators: true) {
                    storyDetailScrollContent(story)
                        .padding(.bottom, 4)
                }
                .frame(maxHeight: maxScrollHeight)

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            storyPopupStoryID = nil
                        }
                        startStory(story, in: viewportSize)
                    } label: {
                        Label(activeStory?.id == story.id ? "Restart Story" : "Start Story", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(StudioPalette.accent)
                    .disabled(story.playback.isEmpty)

                    Spacer()
                }
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StudioPalette.chromeFillStrong)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(StudioPalette.border, lineWidth: 1)
            }
            .shadow(color: StudioPalette.shadow.opacity(0.82), radius: 24, y: 14)
        }
    }

    private func storyRow(_ row: StoryMenuRow, viewportSize: CGSize, searchQuery: String) -> some View {
        let story = row.story

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    storyClusterBadge(label: row.clusterLabel, color: row.clusterColor, searchQuery: searchQuery)

                    highlightedText(
                        story.title,
                        query: searchQuery,
                        font: .system(size: 13, weight: .semibold),
                        matchFont: .system(size: 13, weight: .black)
                    )
                        .foregroundStyle(StudioPalette.primaryText)
                        .lineLimit(1)

                    if let userStoryText = story.userStoryText {
                        Text(userStoryText)
                            .font(.caption)
                            .foregroundStyle(StudioPalette.primaryText.opacity(0.74))
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        highlightedText(
                            row.dateText,
                            query: searchQuery,
                            font: .caption,
                            matchFont: .caption.weight(.black)
                        )
                        Text("\(story.playback.count) \(story.playback.count == 1 ? "beat" : "beats")")
                            .font(.caption)
                        if !story.acceptanceCriteria.isEmpty {
                            Text("\(story.acceptanceCriteria.count) AC")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Button {
                        setStoryReadAloudEnabled(!session.isStoryReadAloudEnabled)
                    } label: {
                        Image(systemName: session.isStoryReadAloudEnabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(session.isStoryReadAloudEnabled ? Color.white : StudioPalette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                session.isStoryReadAloudEnabled
                                    ? StudioPalette.accent
                                    : StudioPalette.headerSurface.opacity(0.82),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.borderless)
                    .help(session.isStoryReadAloudEnabled ? "Disable read aloud" : "Read beats aloud with Kokoro Bella")

                    Button {
                        startStory(story, in: viewportSize)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 30, height: 30)
                            .background(Color.black, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(story.playback.isEmpty)
                    .opacity(story.playback.isEmpty ? 0.4 : 1)
                    .help(activeStory?.id == story.id ? "Restart story" : "Activate story")

                    Button(role: .destructive) {
                        if activeStory?.id == story.id {
                            stopStory()
                        }
                        session.deleteStory(id: story.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioPalette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(StudioPalette.headerSurface.opacity(0.68), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .help("Remove story")
                }
                .padding(.top, 18)
            }
        }
        .padding(12)
        .background(StudioPalette.gridSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(activeStory?.id == story.id ? StudioPalette.foreignKeyTint.opacity(0.45) : StudioPalette.borderSoft)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openStoryPopup(story)
        }
        .onHover { setStoryMenuCardCursorActive($0) }
        .onDisappear { setStoryMenuCardCursorActive(false) }
    }

    private func storyClusterBadge(label: String, color: Color, searchQuery: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            highlightedText(
                label,
                query: searchQuery,
                font: .caption2.weight(.medium),
                matchFont: .caption2.weight(.black)
            )
                .foregroundStyle(StudioPalette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(StudioPalette.headerSurface.opacity(0.78), in: Capsule())
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

    private func setStorySearchCursorActive(_ isActive: Bool) {
        if isActive && !isStorySearchCursorActive {
            NSCursor.iBeam.push()
            isStorySearchCursorActive = true
        } else if !isActive && isStorySearchCursorActive {
            NSCursor.pop()
            isStorySearchCursorActive = false
        }
    }

    private func setStoryMenuCardCursorActive(_ isActive: Bool) {
        if isActive && !isStoryMenuCardCursorActive {
            NSCursor.pointingHand.push()
            isStoryMenuCardCursorActive = true
        } else if !isActive && isStoryMenuCardCursorActive {
            NSCursor.pop()
            isStoryMenuCardCursorActive = false
        }
    }

    private func openStoryPopup(_ story: SchemaSidecar.Story) {
        setStoryMenuCardCursorActive(false)
        withAnimation(.snappy(duration: 0.18)) {
            isStoriesPresented = false
            storyPopupStoryID = story.id
        }
    }

    private func startStory(_ story: SchemaSidecar.Story, in size: CGSize) {
        storyPlaybackTask?.cancel()
        storySpeechNarrator.stop()
        if activeStory == nil {
            preStoryShowAllGraphTableCards = session.showAllGraphTableCards
            preStoryShowStoryCardsInGraph = session.showStoryCardsInGraph
            preStoryShowOnlyStoryCardsInGraph = session.showOnlyStoryCardsInGraph
        }
        if session.showAllGraphTableCards {
            session.setShowAllGraphTableCards(false)
        }
        session.showStoryCardsInGraph = true
        session.showOnlyStoryCardsInGraph = false
        invalidateStoryGraphCardsCache()
        var noNodeAnimation = Transaction()
        noNodeAnimation.animation = nil
        withTransaction(noNodeAnimation) {
            session.clearGraphSelection()
            session.setExpandedGraphNode(nil)
            cardScrollOffsets.removeAll()
        }
        withAnimation(.snappy(duration: 0.18)) {
            isStoriesPresented = false
            storyPopupStoryID = nil
            activeStory = story
            activeStoryPlaybackIndex = story.playback.isEmpty ? nil : Self.storyPreludePlaybackIndex
            selectedStoryID = story.id
            hoveredStoryID = nil
            session.storyPlaybackDisplayedText = ""
            storyHighlightedTableIDs = []
            storyFocusNodeID = nil
            storyRelationTarget = nil
            isStoryPaused = false
            updateReadAloudStatus(.idle)
            activeStoryViewportSize = size
            session.storyPlaybackCardOffset = .zero
            enterGraphFocusSession()
            clearGraphFocusSession(animated: false, restoreViewport: false, clearSavedViewport: false)
            pulledGraphPositions.removeAll()
            tappedRelationTarget = nil
        }
        applyInitialStoryPlaybackFormation(for: story, in: size)

        publishStoryPlaybackOverlay()
        runStoryPlayback(story, from: Self.storyPreludePlaybackIndex, in: size)
    }

    private func applyInitialStoryPlaybackFormation(for story: SchemaSidecar.Story, in size: CGSize) {
        guard let hubCard = storyGraphCards().first(where: { $0.story.id == story.id }) else { return }
        graphFocusTableRelation = nil
        tappedRelationTarget = nil
        applyStoryStarFormation(for: hubCard, animated: true)
        fitGraphFocusViewport(in: size)
    }

    private func runStoryPlayback(_ story: SchemaSidecar.Story, from startIndex: Int, in size: CGSize) {
        storyPlaybackTask?.cancel()
        let clampedStartIndex = min(
            max(startIndex, Self.storyPreludePlaybackIndex),
            max(story.playback.count - 1, Self.storyPreludePlaybackIndex)
        )
        storyPlaybackTask = Task { @MainActor in
            guard !story.playback.isEmpty else {
                storyPlaybackTask = nil
                return
            }

            guard await prepareStoryAudioIfNeeded(for: story) else {
                storyPlaybackTask = nil
                return
            }

            let firstBeatIndex: Int
            if clampedStartIndex == Self.storyPreludePlaybackIndex {
                applyStoryPlaybackPrelude(for: story, in: size)
                await waitForStoryResume(milliseconds: Self.storyPreludeHoldMilliseconds)
                guard !Task.isCancelled else { return }
                firstBeatIndex = 0
            } else {
                firstBeatIndex = clampedStartIndex
            }

            for index in firstBeatIndex..<story.playback.count {
                guard !Task.isCancelled else { return }
                await waitForStoryResume()
                guard !Task.isCancelled else { return }
                let beat = story.playback[index]
                applyStoryPlaybackBeat(beat, index: index, in: size)
                await playStoryBeat(beat)
            }
            storyPlaybackTask = nil
        }
    }

    private func applyStoryPlaybackPrelude(for story: SchemaSidecar.Story, in size: CGSize) {
        var noNodeAnimation = Transaction()
        noNodeAnimation.animation = nil
        withTransaction(noNodeAnimation) {
            session.clearGraphSelection()
            session.setExpandedGraphNode(nil)
            cardScrollOffsets.removeAll()
        }
        withAnimation(.snappy(duration: 0.2)) {
            activeStoryPlaybackIndex = Self.storyPreludePlaybackIndex
            session.storyPlaybackDisplayedText = ""
            storyRelationTarget = nil
            storyHighlightedTableIDs = []
            storyFocusNodeID = nil
        }
        applyInitialStoryPlaybackFormation(for: story, in: size)
        publishStoryPlaybackOverlay()
    }

    private func stopStory() {
        storyPlaybackTask?.cancel()
        storyPlaybackTask = nil
        let shouldRestoreAllGraphTableCards = preStoryShowAllGraphTableCards == true
        let restoredShowStoryCards = preStoryShowStoryCardsInGraph
        let restoredShowOnlyStories = preStoryShowOnlyStoryCardsInGraph
        withAnimation(.snappy(duration: 0.18)) {
            activeStory = nil
            activeStoryPlaybackIndex = nil
            session.storyPlaybackDisplayedText = ""
            storyHighlightedTableIDs = []
            storyFocusNodeID = nil
            storyRelationTarget = nil
            isStoryPaused = false
            activeStoryViewportSize = .zero
            if let savedViewport = preGraphFocusViewport?.restored(for: presentationMode) {
                setViewport(savedViewport, animated: true)
            } else if preGraphFocusViewport != nil {
                fitGraph(in: viewportSize)
            }
            preGraphFocusViewport = nil
            clearGraphFocusSession(animated: false, restoreViewport: false, clearSavedViewport: false)
            pulledGraphPositions.removeAll()
            tappedRelationTarget = nil
            session.setExpandedGraphNode(nil)
            if shouldRestoreAllGraphTableCards {
                session.setShowAllGraphTableCards(true)
            }
            if let restoredShowStoryCards {
                session.showStoryCardsInGraph = restoredShowStoryCards
            }
            if let restoredShowOnlyStories {
                session.showOnlyStoryCardsInGraph = restoredShowOnlyStories
            }
            invalidateStoryGraphCardsCache()
            preStoryShowAllGraphTableCards = nil
            preStoryShowStoryCardsInGraph = nil
            preStoryShowOnlyStoryCardsInGraph = nil
            session.storyPlaybackOverlay = nil
        }
        storySpeechNarrator.stop()
        updateReadAloudStatus(.idle)
    }

    private func toggleStoryPause() {
        if isStoryPaused {
            isStoryPaused = false
            storySpeechNarrator.resume()
            guard storyPlaybackTask == nil,
                  let activeStory,
                  !activeStory.playback.isEmpty
            else {
                publishStoryPlaybackOverlay()
                return
            }
            let currentIndex = activeStoryPlaybackIndex ?? Self.storyPreludePlaybackIndex
            let resumeIndex = currentIndex == Self.storyPreludePlaybackIndex
                ? Self.storyPreludePlaybackIndex
                : min(currentIndex + 1, activeStory.playback.count - 1)
            runStoryPlayback(activeStory, from: resumeIndex, in: activeStoryViewportSize)
        } else {
            isStoryPaused = true
            storySpeechNarrator.pause()
        }
        publishStoryPlaybackOverlay()
    }

    private func jumpStoryPlayback(by delta: Int) {
        guard let activeStory, !activeStory.playback.isEmpty else { return }
        let currentIndex = activeStoryPlaybackIndex ?? Self.storyPreludePlaybackIndex
        let nextIndex = min(
            max(currentIndex + delta, Self.storyPreludePlaybackIndex),
            activeStory.playback.count - 1
        )
        guard nextIndex != currentIndex else { return }

        let shouldResume = !isStoryPaused
        storyPlaybackTask?.cancel()
        storyPlaybackTask = nil

        if nextIndex == Self.storyPreludePlaybackIndex {
            if shouldResume {
                isStoryPaused = false
                runStoryPlayback(activeStory, from: Self.storyPreludePlaybackIndex, in: activeStoryViewportSize)
            } else {
                applyStoryPlaybackPrelude(for: activeStory, in: activeStoryViewportSize)
                isStoryPaused = true
                publishStoryPlaybackOverlay()
            }
            return
        }

        let beat = activeStory.playback[nextIndex]
        if shouldResume {
            isStoryPaused = false
            runStoryPlayback(activeStory, from: nextIndex, in: activeStoryViewportSize)
        } else {
            applyStoryPlaybackBeat(beat, index: nextIndex, in: activeStoryViewportSize)
            session.storyPlaybackDisplayedText = beat.text
            isStoryPaused = true
            publishStoryPlaybackOverlay()
        }
    }

    private func handleStoryPlaybackCommand(_ command: StoryPlaybackCommand.Kind) {
        switch command {
        case .previous:
            jumpStoryPlayback(by: -1)
        case .togglePause:
            toggleStoryPause()
        case .toggleReadAloud:
            toggleStoryReadAloud()
        case .installReadAloud:
            installStoryReadAloud()
        case .next:
            jumpStoryPlayback(by: 1)
        case .stop:
            stopStory()
        }
    }

    private func toggleStoryReadAloud() {
        setStoryReadAloudEnabled(!session.isStoryReadAloudEnabled)
    }

    private func setStoryReadAloudEnabled(_ isEnabled: Bool) {
        guard session.isStoryReadAloudEnabled != isEnabled else {
            publishStoryPlaybackOverlay()
            return
        }

        session.isStoryReadAloudEnabled = isEnabled
        if isEnabled {
            if storySpeechNarrator.isKokoroInstalled {
                updateReadAloudStatus(.idle)
            } else {
                pauseStoryForReadAloudInstall()
                updateReadAloudStatus(.installRequired)
            }

            if storySpeechNarrator.isKokoroInstalled,
               let activeStory,
               !activeStory.playback.isEmpty {
                let currentIndex = min(
                    activeStoryPlaybackIndex ?? Self.storyPreludePlaybackIndex,
                    activeStory.playback.count - 1
                )
                runStoryPlayback(activeStory, from: currentIndex, in: activeStoryViewportSize)
            }
        } else {
            storySpeechNarrator.stop()
            updateReadAloudStatus(.idle)
        }
        publishStoryPlaybackOverlay()
    }

    private func installStoryReadAloud() {
        guard session.isStoryReadAloudEnabled else {
            session.isStoryReadAloudEnabled = true
            return installStoryReadAloud()
        }

        pauseStoryForReadAloudInstall()
        updateReadAloudStatus(.installing("Starting Kokoro install"))
        publishStoryPlaybackOverlay()

        storySpeechNarrator.install { status in
            updateReadAloudStatus(status)
            publishStoryPlaybackOverlay()
        } completion: { didInstall in
            guard didInstall else { return }
            updateReadAloudStatus(.idle)
            if let activeStory,
               !activeStory.playback.isEmpty {
                let currentIndex = activeStoryPlaybackIndex ?? Self.storyPreludePlaybackIndex
                runStoryPlayback(activeStory, from: currentIndex, in: activeStoryViewportSize)
            }
            publishStoryPlaybackOverlay()
        }
    }

    private func pauseStoryForReadAloudInstall() {
        isStoryPaused = true
        storySpeechNarrator.pause()
    }

    private func updateReadAloudStatus(_ status: StoryReadAloudStatus) {
        session.storyReadAloudStatus = status
        session.isStoryReadAloudBusy = status.isBusy
    }

    private func publishStoryPlaybackOverlay() {
        guard let activeStory else {
            session.storyPlaybackOverlay = nil
            return
        }

        let index = activeStoryPlaybackIndex ?? Self.storyPreludePlaybackIndex
        let playbackCount = max(activeStory.playback.count, 1)
        let primaryCluster = session.schemaSidecar.primaryClusterCoverage(for: activeStory)
        session.storyPlaybackOverlay = StoryPlaybackOverlayState(
            title: activeStory.title,
            clusterLabel: primaryCluster?.displayLabel,
            clusterColorHex: primaryCluster?.color,
            userStoryText: activeStory.userStoryText,
            actor: activeStory.actor,
            goal: activeStory.goal,
            benefit: activeStory.benefit,
            conversation: activeStory.conversation,
            acceptanceCriteria: activeStory.acceptanceCriteria.map(\.displayText),
            displayedText: session.storyPlaybackDisplayedText,
            acceptanceText: activeStory.acceptanceCriteria.isEmpty ? nil : acceptanceSummary(for: activeStory),
            index: index,
            playbackCount: playbackCount,
            isPaused: isStoryPaused,
            isReadAloudEnabled: session.isStoryReadAloudEnabled,
            readAloudStatus: session.storyReadAloudStatus,
            isReadAloudBusy: session.isStoryReadAloudBusy,
            canGoBackward: index > Self.storyPreludePlaybackIndex,
            canGoForward: index < activeStory.playback.count - 1
        )
    }

    private func prepareStoryAudioIfNeeded(for story: SchemaSidecar.Story) async -> Bool {
        guard session.isStoryReadAloudEnabled else { return true }
        guard storySpeechNarrator.isKokoroInstalled else {
            pauseStoryForReadAloudInstall()
            updateReadAloudStatus(.installRequired)
            publishStoryPlaybackOverlay()
            return false
        }

        isStoryPaused = true
        updateReadAloudStatus(.preparing("Preparing audio"))
        publishStoryPlaybackOverlay()

        let didPrepare = await storySpeechNarrator.prepare(
            story.playback.map { storySpeechText(for: $0) }
        ) { status in
            updateReadAloudStatus(status)
            publishStoryPlaybackOverlay()
        }

        guard didPrepare else { return false }
        isStoryPaused = false
        updateReadAloudStatus(.idle)
        publishStoryPlaybackOverlay()
        return true
    }

    private func playStoryBeat(_ beat: SchemaSidecar.StoryPlaybackStep) async {
        if session.isStoryReadAloudEnabled {
            let typingTask = Task { @MainActor in
                await typeStoryText(beat.text, durationMilliseconds: nil)
            }
            let didFinishAudio = await storySpeechNarrator.playPrepared(storySpeechText(for: beat)) { status in
                updateReadAloudStatus(status)
                publishStoryPlaybackOverlay()
            }
            await typingTask.value
            if didFinishAudio {
                updateReadAloudStatus(.idle)
                publishStoryPlaybackOverlay()
            }
        } else {
            await typeStoryText(beat.text, durationMilliseconds: beat.durationMilliseconds)
        }
    }

    private func storySpeechText(for beat: SchemaSidecar.StoryPlaybackStep) -> String {
        let spokenText = beat.spokenText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let spokenText, !spokenText.isEmpty {
            return spokenText
        }
        return beat.text
    }

    private static let storyTypeTickMilliseconds = 18
    private static let storyTypeCharactersPerTick = 2
    private static let storyBeatHoldMinimumMilliseconds = 900
    private static let storyPreludePlaybackIndex = -1
    private static let storyPreludeHoldMilliseconds = 5_000

    @MainActor
    private func typeStoryText(_ text: String, durationMilliseconds: Int?) async {
        session.storyPlaybackDisplayedText = ""

        var index = text.startIndex
        while index < text.endIndex {
            guard !Task.isCancelled else { return }
            await waitForStoryResume()
            guard !Task.isCancelled else { return }

            let end = text.index(
                index,
                offsetBy: Self.storyTypeCharactersPerTick,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            session.storyPlaybackDisplayedText.append(contentsOf: text[index..<end])
            index = end
            try? await Task.sleep(for: .milliseconds(Self.storyTypeTickMilliseconds))
        }

        let typedCharacterCount = text.count
        let typingDuration = Self.typingDuration(for: typedCharacterCount)
        let requestedDuration = max(durationMilliseconds ?? 3_800, 2_400)
        let holdDuration = max(Self.storyBeatHoldMinimumMilliseconds, requestedDuration - typingDuration)
        await waitForStoryResume(milliseconds: holdDuration)
    }

    private static func typingDuration(for characterCount: Int) -> Int {
        guard characterCount > 0 else { return 0 }
        let ticks = (characterCount + storyTypeCharactersPerTick - 1) / storyTypeCharactersPerTick
        return ticks * storyTypeTickMilliseconds
    }

    @MainActor
    private func waitForStoryResume(milliseconds: Int? = nil) async {
        var elapsed = 0
        let interval = 80

        while true {
            guard !Task.isCancelled else { return }
            if isStoryPaused {
                try? await Task.sleep(for: .milliseconds(interval))
                continue
            }
            guard let milliseconds else { return }
            guard elapsed < milliseconds else { return }
            let sleepDuration = min(interval, milliseconds - elapsed)
            try? await Task.sleep(for: .milliseconds(sleepDuration))
            elapsed += sleepDuration
        }
    }

    private func applyStoryPlaybackBeat(_ beat: SchemaSidecar.StoryPlaybackStep, index: Int, in size: CGSize) {
        let relationTarget = relationTarget(for: beat.relation)
        var tableIDs = storyTableIDs(for: beat)

        if let relationTarget {
            appendUnique(relationTarget.tableID, to: &tableIDs)
            for relatedID in relatedNodeIDs(for: relationTarget) {
                appendUnique(relatedID, to: &tableIDs)
            }
        }

        let expansionID = firstValidTable([
            beat.expand,
            beat.focus,
            relationTarget?.tableID,
            tableIDs.first,
        ])

        let hubCard = storyGraphCards().first { $0.story.id == activeStory?.id }

        var noNodeAnimation = Transaction()
        noNodeAnimation.animation = nil
        withTransaction(noNodeAnimation) {
            activeStoryPlaybackIndex = index
            storyRelationTarget = relationTarget
            storyHighlightedTableIDs = Set(tableIDs)
            storyFocusNodeID = expansionID
            session.clearGraphSelection()
            session.setExpandedGraphNode(nil)
            cardScrollOffsets.removeAll()
        }

        withAnimation(.snappy(duration: 0.2)) {
            if let hubCard {
                applyStoryStarFormation(for: hubCard, animated: false)
                let starTableIDs = Set(hubCard.tableIDs)
                let extraTableIDs = tableIDs.filter { !starTableIDs.contains($0) }
                if !extraTableIDs.isEmpty {
                    let extraPositions = storyFormationPositions(for: extraTableIDs, focus: expansionID)
                    pulledGraphPositions.merge(extraPositions) { _, new in new }
                }
            } else {
                pulledGraphPositions = storyFormationPositions(for: tableIDs, focus: expansionID)
            }
        }

        if relationTarget == nil {
            tappedRelationTarget = nil
        }

        layoutRevision &+= 1
        fitGraphFocusViewport(in: size)
        publishStoryPlaybackOverlay()
    }

    private func storyTableIDs(for beat: SchemaSidecar.StoryPlaybackStep) -> [String] {
        var result: [String] = []
        for tableID in beat.tables {
            appendUnique(tableID, to: &result)
        }
        appendUnique(beat.focus, to: &result)
        appendUnique(beat.expand, to: &result)
        appendUnique(beat.relation?.table, to: &result)
        return result.filter { session.graph.contains(nodeID: $0) }
    }

    private func relationTarget(for reference: SchemaSidecar.StoryColumnReference?) -> GraphRelationHoverTarget? {
        guard let reference,
              session.graph.contains(nodeID: reference.table),
              session.descriptor(named: reference.table)?.columns.contains(where: { $0.name == reference.column }) == true,
              session.graph.edges.contains(where: { $0.touches(tableID: reference.table, columnName: reference.column) })
        else {
            return nil
        }

        return GraphRelationHoverTarget(
            tableID: reference.table,
            columnName: reference.column,
            endpointKind: .column
        )
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

    private func storyFormationPositions(for tableIDs: [String], focus: String?) -> [String: CGPoint] {
        let validTableIDs = tableIDs.filter { session.graph.contains(nodeID: $0) }
        let uniqueTableIDs = validTableIDs.reduce(into: [String]()) { result, tableID in
            if !result.contains(tableID) {
                result.append(tableID)
            }
        }
        guard uniqueTableIDs.count > 1 else { return [:] }

        let centerID = firstValidTable([focus]) ?? uniqueTableIDs[0]
        let center = session.graphLayout.position(for: centerID)
        let centerSize = nodeSize(for: centerID)
        let companions = uniqueTableIDs.filter { $0 != centerID }
        guard !companions.isEmpty else { return [:] }

        var positions: [String: CGPoint] = [:]
        let maxCompanionExtent = companions
            .map { max(nodeSize(for: $0).width, nodeSize(for: $0).height) }
            .max() ?? GraphCardLayout.expandedWidth
        let centerExtent = max(centerSize.width, centerSize.height)
        let ringGap: CGFloat = 92
        let firstRingCapacity = min(8, max(companions.count, 1))
        let minChordRadius = firstRingCapacity > 1
            ? (maxCompanionExtent + ringGap) / (2 * sin(.pi / CGFloat(firstRingCapacity)))
            : 0
        let baseRadius = max(260, centerExtent / 2 + maxCompanionExtent / 2 + ringGap, minChordRadius)

        var remaining = companions
        var ring = 0
        while !remaining.isEmpty {
            let capacity = ring == 0 ? min(8, remaining.count) : min(12 + ring * 4, remaining.count)
            let ringTables = Array(remaining.prefix(capacity))
            remaining.removeFirst(capacity)

            let radius = baseRadius + CGFloat(ring) * maxCompanionExtent * 0.86 + CGFloat(ring) * 118
            let angleOffset: CGFloat = ring.isMultiple(of: 2) ? -.pi / 2 : -.pi / 2 + (.pi / CGFloat(max(capacity, 1)))

            for (index, tableID) in ringTables.enumerated() {
                let angle: CGFloat
                if capacity == 1 {
                    angle = 0
                } else {
                    angle = angleOffset + (2 * .pi * CGFloat(index) / CGFloat(capacity))
                }
                positions[tableID] = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            }

            ring += 1
        }

        return positions
    }

    private func focusStoryTables(_ tableIDs: [String], fallback: String?, in size: CGSize) {
        var bounds = CGRect.null
        let focusedTables = tableIDs.isEmpty ? [fallback].compactMap { $0 } : tableIDs

        for tableID in focusedTables {
            guard let frame = graphFrame(for: tableID) else { continue }
            bounds = bounds.union(frame)
        }

        guard !bounds.isNull, !bounds.isEmpty else { return }

        let paddedBounds = bounds.insetBy(dx: -84, dy: -84)
        let transform: GraphViewportTransform
        if focusedTables.count <= 1 {
            transform = GraphViewportTransform.focus(
                contentBounds: paddedBounds,
                in: size,
                currentZoom: zoom,
                preferredZoom: 0.96
            )
        } else {
            let minZoom: CGFloat = focusedTables.count > 5 ? 0.26 : 0.34
            let padding: CGFloat = focusedTables.count > 5 ? 190 : 150
            transform = GraphViewportTransform.fit(
                contentBounds: paddedBounds,
                in: size,
                padding: padding,
                minZoom: minZoom,
                maxZoom: 1.02
            )
        }

        setViewport(transform, animated: true)
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

    private func acceptanceSummary(for story: SchemaSidecar.Story) -> String {
        let visibleCriteria = story.acceptanceCriteria
            .map(\.displayText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(2)
        guard !visibleCriteria.isEmpty else { return "\(story.acceptanceCriteria.count) acceptance criteria" }
        return visibleCriteria.joined(separator: " | ")
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
        guard !isStoryOnlyMode else {
            session.setGraphSelection([])
            return
        }
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
                        if !pulledGraphPositions.isEmpty || !pulledStoryGraphPositions.isEmpty {
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

    private func storyDragGesture(storyID: String, in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("graphViewport"))
            .onChanged { value in
                let cards = storyGraphCards()
                guard let card = cards.first(where: { $0.id == storyID }) else { return }

                if draggedStoryID != storyID {
                    draggedStoryID = storyID
                    let currentGraphPoint = storyGraphPoint(for: card)
                    storyDragOrigin = currentGraphPoint
                    let startGraphPoint = GraphViewportTransform(zoom: zoom, pan: pan)
                        .graphPoint(for: value.startLocation, in: canvasSize)
                    storyDragPointerOffset = CGSize(
                        width: startGraphPoint.x - currentGraphPoint.x,
                        height: startGraphPoint.y - currentGraphPoint.y
                    )
                    draggedStoryUsesStarModePull = isStarModeConnectedStory(storyID, in: cards)
                    if draggedStoryUsesStarModePull {
                        hoveredStoryID = storyID
                    } else {
                        selectedStoryID = storyID
                        hoveredStoryID = storyID
                        pulledStoryGraphPositions.removeValue(forKey: storyID)
                    }
                    NSCursor.closedHand.set()
                }

                guard draggedStoryID == storyID else { return }
                let currentGraphPoint = GraphViewportTransform(zoom: zoom, pan: pan)
                    .graphPoint(for: value.location, in: canvasSize)
                let moved = CGPoint(
                    x: currentGraphPoint.x - (storyDragPointerOffset?.width ?? 0),
                    y: currentGraphPoint.y - (storyDragPointerOffset?.height ?? 0)
                )
                if draggedStoryUsesStarModePull {
                    pulledStoryGraphPositions[storyID] = moved
                } else {
                    session.pinStoryGraphPosition(storyID, at: moved)
                }
            }
            .onEnded { _ in
                if draggedStoryUsesStarModePull, let draggedStoryID {
                    if let point = pulledStoryGraphPositions[draggedStoryID] {
                        session.pinStoryGraphPosition(draggedStoryID, at: point)
                    }
                }
                draggedStoryID = nil
                storyDragOrigin = nil
                storyDragPointerOffset = nil
                draggedStoryUsesStarModePull = false
                session.persistStoryGraphLayout()
                NSCursor.arrow.set()
            }
    }

    private func zIndex(for nodeID: String) -> Double {
        if draggedNodeID == nodeID {
            return 4
        }
        if hoveredNodeID == nodeID {
            return 3
        }
        if storyHighlightedTableIDs.contains(nodeID) {
            return 2.5
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

    private func storyGraphCards() -> [StoryGraphCard] {
        cachedStoryGraphCards()
    }

    private func cachedStoryGraphCards() -> [StoryGraphCard] {
        let token = storyGraphCardsCacheToken()
        if !storyGraphCardsCache.isValid || storyGraphCardsCache.token != token {
            storyGraphCardsCache.token = token
            storyGraphCardsCache.cards = computeStoryGraphCards()
            storyGraphCardsCache.isValid = true
        }
        return storyGraphCardsCache.cards
    }

    private func computeStoryGraphCards() -> [StoryGraphCard] {
        StoryGraphPlacement.placedCards(for: session).map { placed in
            StoryGraphCard(
                story: placed.story,
                tableIDs: placed.tableIDs,
                primaryTableIDs: placed.primaryTableIDs,
                clusterKey: placed.clusterKey,
                clusterLabel: placed.clusterLabel,
                clusterColorHex: placed.clusterColorHex,
                clusterColor: placed.clusterColorHex.flatMap { Color(studioHex: $0) },
                graphPosition: placed.graphPosition
            )
        }
    }

    func storyGraphCardsCacheToken() -> Int {
        StoryGraphCardsCacheToken.make(
            layoutRevision: layoutRevision,
            sidecarRevision: clusterTitleCacheKey &+ session.schemaSidecarRevision,
            showStoryCardsInGraph: session.showStoryCardsInGraph,
            showOnlyStoryCardsInGraph: session.showOnlyStoryCardsInGraph,
            showAllGraphTableCards: session.showAllGraphTableCards,
            graphNodeCount: session.graph.nodes.count,
            storyCount: session.stories.count
        )
    }

    private func invalidateStoryGraphCardsCache() {
        storyGraphCardsCache.isValid = false
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

    private func handleStoryOnlyModeChange(in size: CGSize) {
        invalidateClusterTitleCache()
        if isNavigatingFromStories, !isStoryOnlyMode {
            isNavigatingFromStories = false
            return
        }
        clearGraphFocusSession(animated: false)
        layoutRevision &+= 1

        if isStoryOnlyMode {
            if preStoryOnlyViewport == nil {
                preStoryOnlyViewport = GraphViewportBookmark(transform: GraphViewportTransform(zoom: zoom, pan: pan), presentation: presentationMode)
            }
            guard size != .zero else { return }
            if shouldAutoFitStoryViewport {
                fitGraph(in: size)
            }
        } else {
            let saved = preStoryOnlyViewport
            preStoryOnlyViewport = nil
            if let restored = saved?.restored(for: presentationMode) {
                setViewport(restored, animated: true)
            } else if shouldAutoFit, size != .zero {
                refitCurrentScope(in: size)
            }
        }
    }

    private func selectStory(_ story: SchemaSidecar.Story) {
        let isSameSelection = storyStarHubID == story.id
        if !isSameSelection && (storyStarModeSourceID != nil || graphFocusTableRelation != nil || !pulledGraphPositions.isEmpty || !pulledStoryGraphPositions.isEmpty) {
            clearGraphFocusSession()
        }
        withAnimation(.snappy(duration: 0.16)) {
            selectedStoryID = story.id
            session.clearGraphSelection()
            isStoriesPresented = false
        }
    }

    private func storyIsEmphasized(_ storyID: String) -> Bool {
        hoveredStoryID == storyID || storyStarHubID == storyID || activeStory?.id == storyID
    }

    private var storyStarHubID: String? {
        storyStarModeSourceID ?? selectedStoryID
    }

    private func isStarModeConnectedStory(_ storyID: String, in storyCards: [StoryGraphCard]) -> Bool {
        guard let sourceID = storyStarModeSourceID, sourceID != storyID else { return false }
        return relatedStoryIDs(for: sourceID, in: storyCards).contains(storyID)
    }

    private func commitStarModeStoryPositions() {
        for (storyID, point) in pulledStoryGraphPositions {
            session.pinStoryGraphPosition(storyID, at: point)
        }
    }

    private func clearGraphFocusSession(
        animated: Bool = true,
        restoreViewport: Bool = true,
        clearSavedViewport: Bool = true
    ) {
        guard storyStarModeSourceID != nil
            || graphFocusTableRelation != nil
            || !pulledGraphPositions.isEmpty
            || !pulledStoryGraphPositions.isEmpty
        else {
            return
        }

        commitStarModeStoryPositions()
        let savedViewport = preGraphFocusViewport
        let applyClear = {
            pulledGraphPositions.removeAll()
            pulledStoryGraphPositions.removeAll()
            storyStarModeSourceID = nil
            graphFocusTableRelation = nil
            tappedRelationTarget = nil
            if clearSavedViewport {
                preGraphFocusViewport = nil
            }
        }
        if animated {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                applyClear()
            }
        } else {
            applyClear()
        }
        session.persistStoryGraphLayout()
        if restoreViewport, let savedViewport {
            if let restored = savedViewport.restored(for: presentationMode) {
                setViewport(restored, animated: animated)
            } else {
                refitCurrentScope(in: viewportSize)
            }
        }
    }

    private func emphasizedStoryTableIDs(
        for storyCards: [StoryGraphCard],
        focusPlan: GraphFocusPlan? = nil
    ) -> Set<String> {
        if let focusPlan {
            return focusPlan.visibleTableIDs()
        }

        let emphasizedIDs = Set([hoveredStoryID, selectedStoryID, activeStory?.id].compactMap { $0 })
        guard !emphasizedIDs.isEmpty else { return [] }

        var tableIDs: Set<String> = []
        for card in storyCards where emphasizedIDs.contains(card.id) {
            tableIDs.formUnion(card.tableIDs)
        }
        return tableIDs
    }

    private var graphFocusPlan: GraphFocusPlan? {
        if let hubID = storyStarModeSourceID {
            return storyGraphFocusPlan(hubStoryID: hubID)
        }
        if let target = graphFocusTableRelation {
            return tableRelationFocusPlan(target: target)
        }
        return nil
    }

    private var effectiveFocusPlan: GraphFocusPlan? {
        if let activeStory {
            return storyPlaybackFocusPlan(for: activeStory)
        }
        if let graphFocusPlan { return graphFocusPlan }
        if !isStoryOnlyMode, let group = session.graphGrouping.group(id: focusedGroupID ?? "") {
            return GraphFocusPlan(activeStoryIDs: [], relatedStoryIDs: [],
                                  activeTableIDs: Set(GraphExploration.pageOrdered(group.nodeIDs, index: focusedGroupPage).ids),
                                  relatedTableIDs: [])
        }
        return nil
    }

    private func storyPlaybackFocusPlan(for story: SchemaSidecar.Story) -> GraphFocusPlan {
        let storyCards = storyGraphCards()
        let hubCard = storyCards.first { $0.id == story.id }
        let relatedStories = relatedStoryIDs(for: story.id, in: storyCards)
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        let storyTables = Set((hubCard?.tableIDs ?? []).filter { graphTableIDs.contains($0) })
        let activeTables = Set([storyFocusNodeID].compactMap { $0 })
        let relatedTables = storyTables.union(storyHighlightedTableIDs).subtracting(activeTables)
        return GraphFocusPlan(
            activeStoryIDs: [story.id],
            relatedStoryIDs: relatedStories,
            activeTableIDs: activeTables,
            relatedTableIDs: relatedTables
        )
    }

    private func storyGraphFocusPlan(hubStoryID: String) -> GraphFocusPlan {
        let storyCards = storyGraphCards()
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        let hubCard = storyCards.first { $0.id == hubStoryID }
        let relatedStories = relatedStoryIDs(for: hubStoryID, in: storyCards)
        let relatedTables = Set(
            (hubCard?.tableIDs ?? []).filter { graphTableIDs.contains($0) }
        )

        return GraphFocusPlan(
            activeStoryIDs: [hubStoryID],
            relatedStoryIDs: relatedStories,
            activeTableIDs: [],
            relatedTableIDs: relatedTables
        )
    }

    private func tableRelationFocusPlan(target: GraphRelationHoverTarget) -> GraphFocusPlan {
        let relatedTables = Set(GraphExploration.pageOrdered(relatedNodeIDs(for: target), index: relationPageIndex).ids)

        return GraphFocusPlan(
            activeStoryIDs: [],
            relatedStoryIDs: [],
            activeTableIDs: [target.tableID],
            relatedTableIDs: relatedTables
        )
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
            let frame = CGRect(
                x: center.x - nodeSize.width / 2,
                y: center.y - nodeSize.height / 2,
                width: nodeSize.width,
                height: nodeSize.height
            )
            bounds = bounds.isNull ? frame : bounds.union(frame)
        }

        for card in storyGraphCards() where plan.tierForStory(card.id) != .hidden {
            let center = storyGraphPoint(for: card)
            let frame = CGRect(
                x: center.x - StoryGraphCardLayout.width / 2,
                y: center.y - StoryGraphCardLayout.height / 2,
                width: StoryGraphCardLayout.width,
                height: StoryGraphCardLayout.height
            )
            bounds = bounds.isNull ? frame : bounds.union(frame)
        }

        guard !bounds.isNull else { return }
        let transform = GraphViewportTransform.fit(
            contentBounds: bounds,
            in: size,
            padding: 72,
            minZoom: isLargeGraph ? 0.01 : 0.22,
            maxZoom: 1.05
        )
        setViewport(transform, animated: true)
    }

    @ViewBuilder
    private func graphFocusBanner(focusPlan: GraphFocusPlan) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                Text(graphFocusBannerTitle(focusPlan: focusPlan))
                    .font(.caption.weight(.semibold))
                if let target = graphFocusTableRelation {
                    let page = GraphExploration.pageOrdered(relatedNodeIDs(for: target), index: relationPageIndex)
                    if page.count > 1 {
                        Button { pullConnectedNodesIntoView(for: target, pageIndex: page.index - 1) } label: {
                            Image(systemName: "chevron.left")
                        }.disabled(page.index == 0).help("Previous related tables")
                        Text("\(page.start)–\(page.end) of \(page.total) related").font(.caption)
                        Button { pullConnectedNodesIntoView(for: target, pageIndex: page.index + 1) } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(page.index + 1 == page.count).help("Next related tables")
                    }
                }
                Spacer(minLength: 0)
                Button("Done") {
                    clearGraphFocusSession()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
            }
            .foregroundStyle(StudioPalette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(StudioPalette.chromeFillStrong, in: Capsule())
            .overlay { Capsule().stroke(StudioPalette.border, lineWidth: 1) }
            .padding(.top, 12)
            .padding(.horizontal, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }

    private func graphFocusBannerTitle(focusPlan: GraphFocusPlan) -> String {
        let storyCount = focusPlan.visibleStoryIDs().count
        let tableCount = focusPlan.visibleTableIDs().count
        var parts: [String] = ["Focus"]
        if storyCount > 0 {
            parts.append("\(storyCount) \(storyCount == 1 ? "story" : "stories")")
        }
        if tableCount > 0 {
            parts.append("\(tableCount) \(tableCount == 1 ? "table" : "tables")")
        }
        return parts.joined(separator: " · ")
    }

    private func relatedStoryIDs(for storyID: String, in storyCards: [StoryGraphCard]) -> Set<String> {
        var relatedIDs: Set<String> = []
        for card in storyCards {
            if card.id == storyID {
                for relation in card.story.relatedStories where !relation.storyID.isEmpty {
                    relatedIDs.insert(relation.storyID)
                }
            }
            if card.story.relatedStories.contains(where: { $0.storyID == storyID }) {
                relatedIDs.insert(card.id)
            }
        }
        relatedIDs.remove(storyID)
        return relatedIDs
    }

    private func storyRelationDirection(for kind: String) -> StoryRelationDirection {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "follows", "follow", "blocked_by", "requires":
            return .targetToSource
        case "precedes", "precede", "depends_on", "depends", "extends", "blocks":
            return .sourceToTarget
        default:
            return .none
        }
    }

    private func storyRelationDisplayName(_ kind: String) -> String {
        let cleaned = kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return cleaned.isEmpty ? "related" : cleaned
    }

    private func storyScreenCenter(for card: StoryGraphCard, in canvasSize: CGSize) -> CGPoint {
        GraphViewportTransform(zoom: zoom, pan: pan)
            .point(for: storyGraphPoint(for: card), in: canvasSize)
    }

    private func storyGraphPoint(for card: StoryGraphCard) -> CGPoint {
        pulledStoryGraphPositions[card.id] ?? session.pinnedStoryGraphPosition(for: card.id) ?? card.graphPosition
    }

    private func storyFrame(for card: StoryGraphCard, in canvasSize: CGSize) -> CGRect {
        let center = storyScreenCenter(for: card, in: canvasSize)
        let scaledSize = CGSize(
            width: StoryGraphCardLayout.width * zoom,
            height: StoryGraphCardLayout.height * zoom
        )
        return CGRect(
            x: center.x - scaledSize.width / 2,
            y: center.y - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
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
        guard session.showClusterHalos, let hex = session.clusterColorHex(for: nodeID) else { return nil }
        if let color = scenePreparation.colors[hex] { return color }
        let color = Color(studioHex: hex)
        scenePreparation.colors[hex] = color
        return color
    }

    private func worldFrames(focusPlan: GraphFocusPlan?) -> [String: CGRect] {
        let key = GraphSceneWorldKey(
            graphRevision: session.graphRevision, layoutRevision: layoutRevision, presentation: presentationMode,
            hoveredID: hoveredNodeID, draggedID: draggedNodeID, expandedIDs: session.expandedGraphNodeIDs,
            relationTarget: storyRelationTarget ?? tappedRelationTarget ?? hoveredRelationTarget,
            pulledPositions: pulledGraphPositions, visibleIDs: focusPlan?.visibleTableIDs(), storyOnly: isStoryOnlyMode
        )
        if scenePreparation.worldKey == key { return scenePreparation.worldFrames }
        let ids = isStoryOnlyMode ? [] : session.graph.nodes.compactMap { node in
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
            frames: frames, viewport: CGRect(origin: .zero, size: size), zoom: zoom, isLarge: isLargeGraph,
            emphasized: session.selectedGraphNodeIDs.union(focusPlan?.visibleTableIDs() ?? []),
            primary: primary, retained: retained, contentRevision: scenePreparation.contentRevision,
            roleForNode: cardRole, descriptorForNode: session.descriptor(named:), displayedColumnsForNode: visibleColumnNames
        )
    }

    private func cachedRelationHighlight(focusNodeID: String?, hoverTarget: GraphRelationHoverTarget?,
                                         edgeLookup: GraphTopologyIndex) -> GraphRelationHighlight {
        let key = GraphSceneHighlightKey(graphRevision: session.graphRevision, focusID: focusNodeID, target: hoverTarget)
        if scenePreparation.highlightKey == key, let highlight = scenePreparation.highlight { return highlight }
        let highlight = GraphRelationHighlight(graph: session.graph, focusNodeID: focusNodeID,
                                              hoverTarget: hoverTarget, edgeLookup: edgeLookup)
        scenePreparation.highlightKey = key
        scenePreparation.highlight = highlight
        return highlight
    }

    private func graphBoundsAnchorMap() -> GraphAnchorMap {
        let nodeCards = Dictionary(uniqueKeysWithValues: session.graph.nodes.map { node in
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
        let fitMinimumZoom: CGFloat = session.graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 0.005 : 0.45
        let fitPadding: CGFloat = session.graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 72 : 120
        if shouldAutoFitStoryViewport {
            transform = GraphViewportTransform.fit(
                contentBounds: bounds,
                in: size,
                padding: 56,
                minZoom: 0.35,
                maxZoom: 1.0
            )
        } else {
            transform = GraphViewportTransform.fit(
                contentBounds: bounds,
                in: size,
                padding: fitPadding,
                minZoom: fitMinimumZoom
            )
        }
        setViewport(transform, animated: true)
    }

    private func graphContentBoundsForFit() -> CGRect {
        if isStoryOnlyMode {
            var storyBounds = CGRect.zero
            for card in storyGraphCards() {
                let graphPoint = storyGraphPoint(for: card)
                let frame = CGRect(
                    x: graphPoint.x - StoryGraphCardLayout.width / 2,
                    y: graphPoint.y - StoryGraphCardLayout.height / 2,
                    width: StoryGraphCardLayout.width,
                    height: StoryGraphCardLayout.height
                )
                storyBounds = storyBounds.isEmpty ? frame : storyBounds.union(frame)
            }
            return storyBounds
        }

        var bounds = graphBoundsAnchorMap().contentBounds
        guard session.showStoryCardsInGraph else { return bounds }

        for card in storyGraphCards() {
            let graphPoint = storyGraphPoint(for: card)
            let frame = CGRect(
                x: graphPoint.x - StoryGraphCardLayout.width / 2,
                y: graphPoint.y - StoryGraphCardLayout.height / 2,
                width: StoryGraphCardLayout.width,
                height: StoryGraphCardLayout.height
            )
            bounds = bounds.union(frame)
        }

        return bounds
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

    private func clusterTitleCacheToken(focusPlan: GraphFocusPlan?, playbackKey: Int) -> Int {
        ClusterTitleCacheToken.make(
            layoutRevision: layoutRevision,
            sidecarRevision: clusterTitleCacheKey &+ session.schemaSidecarRevision,
            playbackKey: playbackKey,
            isStoryOnlyMode: isStoryOnlyMode,
            hasFocusPlan: focusPlan != nil,
            showClusterHalos: session.showClusterHalos
        )
    }

    private func invalidateClusterTitleCache() {
        clusterTitleCacheKey &+= 1
        clusterTitleCache.cacheKey = -1
        clusterTitleCache.entries = []
        invalidateStoryGraphCardsCache()
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
        } else if hoveredStoryID == nil && draggedStoryID == nil {
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
        storyStarModeSourceID = nil
        pulledStoryGraphPositions.removeAll()
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
        let layout = GraphFocusRingLayout.graphPositions(
            hubCenter: hubCenter,
            hubSize: hubSize,
            items: items,
            gap: 88,
            interItemGap: 36
        )

        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            pulledGraphPositions = layout
        }
        fitGraphFocusViewport(in: viewportSize)
    }

    /// Enters story focus: hides unrelated cards, lays out linked stories and covered tables without overlap, and zooms to fit.
    private func pullStoryConnectionsIntoView(for card: StoryGraphCard) {
        guard draggedNodeID == nil else { return }

        let currentStoryCards = storyGraphCards()
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        let relatedStoryIDs = relatedStoryIDs(for: card.id, in: currentStoryCards)
        let tableIDs = card.tableIDs.filter { graphTableIDs.contains($0) }
        guard !relatedStoryIDs.isEmpty || !tableIDs.isEmpty else { return }

        enterGraphFocusSession()
        graphFocusTableRelation = nil
        tappedRelationTarget = nil
        applyStoryStarFormation(for: card, animated: true)
        fitGraphFocusViewport(in: viewportSize)
    }

    private func applyStoryStarFormation(for card: StoryGraphCard, animated: Bool) {
        let currentStoryCards = storyGraphCards()
        let storyCardsByID = Dictionary(uniqueKeysWithValues: currentStoryCards.map { ($0.id, $0) })
        let graphTableIDs = Set(session.graph.nodes.map(\.id))
        let relatedStoryIDs = relatedStoryIDs(for: card.id, in: currentStoryCards)
            .filter { storyCardsByID[$0] != nil }
            .sorted { lhs, rhs in
                let lhsTitle = storyCardsByID[lhs]?.story.title ?? lhs
                let rhsTitle = storyCardsByID[rhs]?.story.title ?? rhs
                return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
            }
        let tableIDs = card.tableIDs
            .filter { graphTableIDs.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let hubCenter = storyGraphPoint(for: card)
        let (nextTablePositions, nextStoryPositions) = StoryStarFormationLayout.graphPositions(
            hubCenter: hubCenter,
            relatedStoryIDs: relatedStoryIDs,
            tableIDs: tableIDs,
            tableSize: { nodeSize(for: $0) }
        )

        let apply = {
            pulledGraphPositions = nextTablePositions
            pulledStoryGraphPositions = nextStoryPositions
            storyStarModeSourceID = card.id
        }

        if animated {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                apply()
            }
        } else {
            apply()
        }
    }

    private func storyPullTargetSize(for target: StoryPullTarget) -> CGSize {
        switch target.kind {
        case .table:
            return nodeSize(for: target.id)
        case .story:
            return CGSize(width: StoryGraphCardLayout.width, height: StoryGraphCardLayout.height)
        }
    }

    private func relatedNodeIDs(for target: GraphRelationHoverTarget) -> [String] {
        let key = GraphSceneHighlightKey(graphRevision: session.graphRevision, focusID: nil, target: target)
        if scenePreparation.relatedKey == key { return scenePreparation.relatedIDs }
        let index = topologyCache.index(for: session.graph, graphRevision: session.graphRevision)
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
        guard let graphFrame = graphFrame(for: nodeID) else { return }
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
        let current = GraphViewportTransform(zoom: zoom, pan: pan)
        let next = current.magnified(
            by: magnification, at: anchor, in: size,
            minZoom: isLargeGraph ? 0.005 : 0.12
        )
        guard next != current else { return }
        zoom = next.zoom
        baseZoom = next.zoom
        pan = next.pan
        panStart = next.pan
    }
}

private struct StoryGraphCard: Identifiable {
    let story: SchemaSidecar.Story
    let tableIDs: [String]
    let primaryTableIDs: [String]
    let clusterKey: String
    let clusterLabel: String?
    let clusterColorHex: String?
    let clusterColor: Color?
    let graphPosition: CGPoint

    var id: String { story.id }
}

private struct StoryMenuRow: Identifiable {
    let story: SchemaSidecar.Story
    let dateText: String
    let rawDateText: String
    let clusterLabel: String
    let clusterColor: Color

    var id: String { story.id }
}

private enum StoryRelationDirection {
    case sourceToTarget
    case targetToSource
    case none
}

private struct StoryPullTarget {
    let kind: StoryPullTargetKind
    let id: String
}

private enum StoryPullTargetKind {
    case table
    case story
}

private struct StoryGraphCardsCache {
    var isValid = false
    var token = 0
    var cards: [StoryGraphCard] = []
}

private struct StorySchemaCardView: View {
    let story: SchemaSidecar.Story
    let clusterLabel: String?
    let clusterColor: Color?
    let tableCount: Int
    let relationCount: Int
    let isActive: Bool
    let isSelected: Bool
    let isHovered: Bool
    let isDragging: Bool
    let isConnected: Bool
    var allowHoverEffects: Bool = true
    let selectStory: () -> Void
    let startStory: () -> Void
    let pullConnections: () -> Void
    let hoverChanged: (Bool) -> Void
    let openDetail: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(clusterColor ?? StudioPalette.accentSoft)
                .frame(width: 3)
                .clipShape(Capsule())
                .opacity(isActive || isSelected || isHovered || isDragging ? 0.95 : 0.68)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioPalette.secondaryText)

                    Text(clusterLabel ?? "Story")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    Button(action: pullConnections) {
                        Image(systemName: "scope")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StudioPalette.secondaryText)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Bring covered tables and linked stories closer")

                    Button(action: startStory) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StudioPalette.primaryText)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Start story playback")
                }

                Text(story.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(tableCount == 1 ? "1 table" : "\(tableCount) tables")
                    if relationCount > 0 {
                        Text(relationCount == 1 ? "1 link" : "\(relationCount) links")
                    }
                    if isConnected {
                        Text("related")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioPalette.tertiaryText)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: isActive || isSelected || isHovered || isDragging ? 1.35 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2, perform: openDetail)
        .onTapGesture(perform: selectStory)
        .onHover { isHovered in
            if isHovered {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
            hoverChanged(isHovered)
        }
        .scaleEffect(isDragging ? 1.025 : (allowHoverEffects && isHovered ? 1.018 : 1))
        .animation(allowHoverEffects ? .snappy(duration: 0.16) : nil, value: isHovered)
        .help("Double-click for details. Drag to move.")
    }

    private var backgroundFill: Color {
        if isActive || isSelected || isDragging {
            return Color.white.opacity(0.96)
        }
        if isConnected {
            return Color.white.opacity(0.9)
        }
        return Color.white.opacity(isHovered ? 0.94 : 0.86)
    }

    private var borderColor: Color {
        if let clusterColor {
            return clusterColor.opacity(isActive || isSelected || isHovered || isDragging ? 0.72 : (isConnected ? 0.52 : 0.36))
        }
        return StudioPalette.borderStrong.opacity(isActive || isSelected || isHovered || isDragging ? 0.95 : (isConnected ? 0.78 : 0.62))
    }
}

private struct FeaturesMenuButton: View {
    @Binding var isOpen: Bool
    @Binding var showCardinals: Bool
    @Binding var showClusterHalos: Bool
    let hasClusters: Bool
    let storyCount: Int
    let onOpenStories: () -> Void

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
                onOpenStories()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(storyCount > 0 ? StudioPalette.accent : StudioPalette.secondaryText)
                    Text(storyCount > 0 ? "Stories \(storyCount)" : "Stories")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StudioPalette.primaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .onHover { isHovered in
                if isHovered {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("Open story flows")

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
                .help("Show or hide colored borders on clustered nodes.")
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
    let clusterColor: Color?
    let columnDescription: (String) -> String?
    let previewColumns: [TableColumn]
    let outgoingEdges: [GraphEdge]
    let incomingEdges: [GraphEdge]
    let isSelected: Bool
    let isMultiSelected: Bool
    let viewportZoom: CGFloat
    let displayStyle: GraphNodeCardStyle
    let scrollOffset: CGFloat
    let isHovered: Bool
    let isDragging: Bool
    let isStoryHighlighted: Bool
    let highlightState: GraphNodeHighlightState
    let keepsTextReadableWhenZoomed: Bool
    let selectNode: () -> Void
    let toggleExpanded: () -> Void
    let openTable: () -> Void
    let showTopRows: () -> Void
    let usesViewportHoverTracking: Bool
    let hoverChanged: (Bool) -> Void
    let relationHoverChanged: (GraphRelationHoverTarget, GraphRelationHoverSource, Bool) -> Void
    let relationTapped: (GraphRelationHoverTarget) -> Void
    let headerDragGesture: HeaderGesture
    @State private var storySpotlightPulse = false

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
                if isStoryHighlighted {
                    backgroundShape.fill(storySpotlightFill)
                        .opacity(storySpotlightPulse ? 0.9 : 0.48)
                }
                let strokeWidth = borderLineWidth
                let strokeColor = isMultiSelected ? StudioPalette.accent : borderColor
                backgroundShape.strokeBorder(strokeColor, lineWidth: strokeWidth)
            }
        }
        .clipShape(backgroundShape)
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
        .onAppear {
            storySpotlightPulse = isStoryHighlighted
        }
        .onChange(of: isStoryHighlighted) { _, highlighted in
            storySpotlightPulse = highlighted
        }
        .animation(
            isStoryHighlighted
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : .default,
            value: storySpotlightPulse
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: displayStyle)
    }

    private var header: some View {
        HStack(spacing: 8) {
            let hasDescription = tableDescription != nil
            Text(node.title)
                .font(.system(size: showsDetailRows ? 13 : 12, weight: .semibold))
                .foregroundStyle(StudioPalette.primaryText)
                .underline(hasDescription, color: StudioPalette.primaryText.opacity(0.4))
                .lineLimit(1)
                .layoutPriority(1)
                .opacity(nameZoomOpacity)

            Spacer(minLength: 0)

            Text(fieldCountLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StudioPalette.headerSurface, in: Capsule())
                .opacity(metadataZoomOpacity)

            if let rowCountLabel {
                Text(rowCountLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioPalette.headerSurface.opacity(0.74), in: Capsule())
                    .opacity(metadataZoomOpacity)
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
        return zoomOpacity(start: 0.88, end: 0.42, minimum: isSelected || isHovered ? 0.56 : 0.08)
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

    private var storySpotlightFill: AnyShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.28),
                    Color(red: 1.0, green: 0.46, blue: 0.24).opacity(0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
    let storyOnly: Bool
}

private struct GraphSceneHighlightKey: Equatable {
    let graphRevision: Int
    let focusID: String?
    let target: GraphRelationHoverTarget?
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

    private var isStoryOnlyMode: Bool {
        session.showStoryCardsInGraph && session.showOnlyStoryCardsInGraph
    }

    private var storyCards: [StoryGraphPlacedCard] {
        StoryGraphPlacement.placedCards(for: session)
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
                
                if isStoryOnlyMode {
                    drawStoryMinimap(in: &context, size: size, minimapTransform: minimapTransform)
                } else {
                    drawSchemaMinimap(in: &context, size: size, minimapTransform: minimapTransform)
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

    private func drawSchemaMinimap(
        in context: inout GraphicsContext,
        size: CGSize,
        minimapTransform: GraphViewportTransform
    ) {
        var edgePath = Path()
        for edge in session.graph.edges {
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
        for node in session.graph.nodes {
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

    private func drawStoryMinimap(
        in context: inout GraphicsContext,
        size: CGSize,
        minimapTransform: GraphViewportTransform
    ) {
        let cardsByID = Dictionary(uniqueKeysWithValues: storyCards.map { ($0.id, $0) })

        for card in storyCards {
            for relation in card.story.relatedStories {
                guard let targetCard = cardsByID[relation.storyID] else { continue }
                let minimapSource = minimapTransform.point(for: card.graphPosition, in: size)
                let minimapTarget = minimapTransform.point(for: targetCard.graphPosition, in: size)

                var path = Path()
                path.move(to: minimapSource)
                path.addLine(to: minimapTarget)
                context.stroke(
                    path,
                    with: .color(StudioPalette.primaryText.opacity(0.2)),
                    lineWidth: 0.5
                )
            }
        }

        for card in storyCards {
            let minimapPos = minimapTransform.point(for: card.graphPosition, in: size)
            let nodeRect = CGRect(
                x: minimapPos.x - 3,
                y: minimapPos.y - 2,
                width: 6,
                height: 4
            )
            context.fill(
                Path(roundedRect: nodeRect, cornerRadius: 1),
                with: .color(StudioPalette.accent.opacity(0.75))
            )
        }
    }
    
    private func graphContentBounds() -> CGRect {
        let padding: CGFloat = 100

        if isStoryOnlyMode {
            let storyBounds = StoryGraphPlacement.contentBounds(for: storyCards)
            guard !storyBounds.isEmpty else { return .zero }
            return storyBounds.insetBy(dx: -padding, dy: -padding)
        }

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
