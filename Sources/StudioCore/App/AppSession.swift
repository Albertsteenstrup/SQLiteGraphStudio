import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class AppSession {
    public var databaseURL: URL?
    public var tables: [TableSummary] = []
    public var graph: SchemaGraph = .empty
    public var leftPane = WorkspacePaneState(kind: .schema)
    public var rightPane = WorkspacePaneState(kind: .tables)
    public var activePaneSide: WorkspacePaneSide = .right
    public var selectedGraphNodeID: String?
    public var expandedGraphNodeIDs: Set<String> = []
    public var floatingDetailsCardTableID: String?
    public var floatingDetailsCardPosition: CGPoint?
    public var showAllGraphTableCards = false
    public var openTabs: [TableTabModel] = []
    public var activeTabID: UUID?
    public var isRefreshing = false
    public var isTablePickerPresented = false
    public var presentedError: SQLiteUserError?

    public let graphLayout = GraphLayoutModel()
    public var queryWorkspace: QueryWorkspaceModel

    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var tableDescriptors: [String: EditableTableDescriptor] = [:]

    public init(
        databaseService: DatabaseService = DatabaseService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.databaseService = databaseService
        self.userDefaults = userDefaults
        self.queryWorkspace = QueryWorkspaceModel(databaseService: databaseService)
    }

    public var activeTab: TableTabModel? {
        openTabs.first(where: { $0.id == activeTabID }) ?? openTabs.first
    }

    public var hasOpenDatabase: Bool {
        databaseURL != nil
    }

    public var databaseDisplayName: String {
        databaseURL?.lastPathComponent ?? "No Database"
    }

    public func presentOpenDatabasePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite"),
            UTType(filenameExtension: "sqlite3"),
            UTType(filenameExtension: "db"),
            UTType(filenameExtension: "sqlite-db"),
            UTType(filenameExtension: "sqlitedb"),
        ].compactMap { $0 }
        panel.prompt = "Open Database"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openDatabase(url: url) }
    }

    public func openDatabase(url: URL) async {
        isRefreshing = true
        presentedError = nil
        defer { isRefreshing = false }

        do {
            try await databaseService.open(url: url)
            let snapshot = try await databaseService.loadCatalogSnapshot()
            apply(snapshot: snapshot, url: url)
            StudioLog.ui.info("Loaded database session for \(url.lastPathComponent, privacy: .public)")
        } catch {
            presentedError = SQLiteUserError.from(error)
        }
    }

    public func closeDatabase() {
        Task {
            await databaseService.close()
        }
        databaseURL = nil
        tables = []
        graph = .empty
        leftPane = WorkspacePaneState(kind: .schema)
        rightPane = WorkspacePaneState(kind: .tables)
        activePaneSide = .right
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        openTabs = []
        activeTabID = nil
        tableDescriptors = [:]
        graphLayout.reset(for: .empty)
        queryWorkspace.reset()
    }

    public func refreshSchema() {
        guard let databaseURL else { return }
        Task { await openDatabase(url: databaseURL) }
    }

    public func showTablePicker() {
        guard !tables.isEmpty else { return }
        isTablePickerPresented = true
    }

    public func dismissTablePicker() {
        isTablePickerPresented = false
    }

    @discardableResult
    public func openTable(named tableName: String, autoLoad: Bool = true) -> TableTabModel? {
        guard let descriptor = tableDescriptors[tableName] else {
            presentedError = SQLiteUserError(kind: .notFound, message: "Table \(tableName) was not found.")
            return nil
        }

        if let existingTab = openTabs.first(where: { $0.descriptor.name == tableName }) {
            activeTabID = existingTab.id
            ensurePaneVisible(.tables)
            if let tablePaneSide = side(containing: .tables) {
                activePaneSide = tablePaneSide
            }
            return existingTab
        }

        let tab = TableTabModel(descriptor: descriptor, databaseService: databaseService)
        openTabs.append(tab)
        activeTabID = tab.id
        ensurePaneVisible(.tables)
        if let tablePaneSide = side(containing: .tables) {
            activePaneSide = tablePaneSide
        }
        dismissTablePicker()
        StudioLog.ui.info("Opened table tab: \(tableName, privacy: .public)")
        if autoLoad {
            Task { await tab.reload() }
        }
        return tab
    }

    public func closeTab(id: UUID) {
        openTabs.removeAll { $0.id == id }
        if activeTabID == id {
            activeTabID = openTabs.last?.id
        }
    }

    public func selectTab(id: UUID) {
        activeTabID = id
    }

    public func selectGraphNode(_ nodeID: String?) {
        guard nodeID == nil || graph.contains(nodeID: nodeID!) else { return }
        selectedGraphNodeID = nodeID
        if let nodeID {
            StudioLog.ui.debug("Selected graph node: \(nodeID, privacy: .public)")
        }
    }

    public func showFloatingDetails(for tableID: String, preferredPosition: CGPoint? = nil) {
        guard graph.contains(nodeID: tableID) else { return }
        selectGraphNode(tableID)
        floatingDetailsCardTableID = tableID
        if let preferredPosition {
            floatingDetailsCardPosition = preferredPosition
        }
    }

    public func closeFloatingDetails() {
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
    }

    public func updateFloatingDetailsPosition(_ position: CGPoint) {
        floatingDetailsCardPosition = position
    }

    public func setShowAllGraphTableCards(_ isPresented: Bool) {
        showAllGraphTableCards = isPresented
        if isPresented {
            closeFloatingDetails()
        }
    }

    public func isGraphNodeExpanded(_ nodeID: String) -> Bool {
        showAllGraphTableCards || expandedGraphNodeIDs.contains(nodeID)
    }

    public func toggleGraphNodeExpansion(_ nodeID: String) {
        guard graph.contains(nodeID: nodeID) else { return }
        if expandedGraphNodeIDs.contains(nodeID) {
            expandedGraphNodeIDs.remove(nodeID)
        } else {
            expandedGraphNodeIDs.insert(nodeID)
        }
    }

    public func setExpandedGraphNode(_ nodeID: String?) {
        guard let nodeID else {
            expandedGraphNodeIDs.removeAll()
            return
        }
        guard graph.contains(nodeID: nodeID) else { return }
        expandedGraphNodeIDs = [nodeID]
    }

    public func collapseExpandedGraphNodes() {
        expandedGraphNodeIDs.removeAll()
    }

    public func persistCurrentGraphLayout() {
        guard let databaseURL, !graph.nodes.isEmpty else { return }
        let snapshot = graphLayout.snapshot(for: graph)
        let persistedLayout = PersistedGraphLayout(snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(persistedLayout) else { return }
        userDefaults.set(data, forKey: graphLayoutStorageKey(for: databaseURL))
    }

    public func openSelectedGraphNode() {
        guard let selectedGraphNodeID else { return }
        openTable(named: selectedGraphNodeID)
    }

    public func dismissError() {
        presentedError = nil
    }

    public func descriptor(named tableName: String) -> EditableTableDescriptor? {
        tableDescriptors[tableName]
    }

    public func outgoingEdges(for tableName: String) -> [GraphEdge] {
        graph.edges
            .filter { $0.sourceID == tableName }
            .sorted { lhs, rhs in
                if lhs.sourceColumn == rhs.sourceColumn {
                    return lhs.targetID.localizedStandardCompare(rhs.targetID) == .orderedAscending
                }
                return lhs.sourceColumn.localizedStandardCompare(rhs.sourceColumn) == .orderedAscending
            }
    }

    public func incomingEdges(for tableName: String) -> [GraphEdge] {
        graph.edges
            .filter { $0.targetID == tableName }
            .sorted { lhs, rhs in
                if lhs.sourceID == rhs.sourceID {
                    return lhs.sourceColumn.localizedStandardCompare(rhs.sourceColumn) == .orderedAscending
                }
                return lhs.sourceID.localizedStandardCompare(rhs.sourceID) == .orderedAscending
            }
    }

    public func paneState(for side: WorkspacePaneSide) -> WorkspacePaneState {
        switch side {
        case .left:
            return leftPane
        case .right:
            return rightPane
        }
    }

    public func side(containing kind: PaneContentKind) -> WorkspacePaneSide? {
        if leftPane.kind == kind {
            return .left
        }
        if rightPane.kind == kind {
            return .right
        }
        return nil
    }

    public func ensurePaneVisible(_ kind: PaneContentKind, preferredSide: WorkspacePaneSide = .right) {
        guard side(containing: kind) == nil else { return }
        setPaneContent(kind, for: preferredSide)
    }

    public func setActivePaneSide(_ side: WorkspacePaneSide) {
        activePaneSide = side
    }

    public func setPaneContent(_ kind: PaneContentKind, for side: WorkspacePaneSide) {
        activePaneSide = side
        guard paneState(for: side).kind != kind else { return }

        if paneState(for: side.opposite).kind == kind {
            swapPaneContents()
            return
        }

        switch side {
        case .left:
            leftPane.kind = kind
        case .right:
            rightPane.kind = kind
        }
    }

    public func swapPaneContents() {
        let leftKind = leftPane.kind
        leftPane.kind = rightPane.kind
        rightPane.kind = leftKind
    }

    public func applyDockItem(_ item: WorkspaceDockItem, to side: WorkspacePaneSide) {
        setPaneContent(item.kind, for: side)
    }

    private func apply(snapshot: CatalogSnapshot, url: URL) {
        databaseURL = url
        tableDescriptors = Dictionary(uniqueKeysWithValues: snapshot.descriptors.map { ($0.name, $0) })
        tables = snapshot.descriptors.map(\.summary)
        graph = snapshot.graph
        graphLayout.reset(for: snapshot.graph)
        restorePersistedGraphLayoutIfAvailable(for: url, graph: snapshot.graph)
        activePaneSide = .right
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        queryWorkspace.reset()
        openTabs = openTabs.compactMap { existingTab in
            guard let descriptor = tableDescriptors[existingTab.descriptor.name] else { return nil }
            let replacement = TableTabModel(
                descriptor: descriptor,
                databaseService: databaseService,
                state: existingTab.queryState
            )
            Task { await replacement.reload() }
            return replacement
        }
        activeTabID = openTabs.last?.id
    }

    private func graphLayoutStorageKey(for url: URL) -> String {
        "SQLiteGraphStudio.graph-layout.\(url.path)"
    }

    private func restorePersistedGraphLayoutIfAvailable(for url: URL, graph: SchemaGraph) {
        guard let data = userDefaults.data(forKey: graphLayoutStorageKey(for: url)),
              let persistedLayout = try? JSONDecoder().decode(PersistedGraphLayout.self, from: data)
        else {
            return
        }

        graphLayout.restore(
            persistedLayout.snapshot,
            for: graph,
            presentation: .compact,
            descriptorLookup: { [tableDescriptors] in tableDescriptors[$0] }
        )
    }
}

private struct PersistedGraphLayout: Codable {
    let positions: [String: PersistedPoint]
    let pinnedPositions: [String: PersistedPoint]

    init(snapshot: GraphLayoutSnapshot) {
        positions = snapshot.positions.mapValues(PersistedPoint.init)
        pinnedPositions = snapshot.pinnedPositions.mapValues(PersistedPoint.init)
    }

    var snapshot: GraphLayoutSnapshot {
        GraphLayoutSnapshot(
            positions: positions.mapValues(\.cgPoint),
            pinnedPositions: pinnedPositions.mapValues(\.cgPoint)
        )
    }
}

private struct PersistedPoint: Codable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
