import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class AppSession {
    public var recentDatabaseURLs: [URL] = []
    public var connectionProfiles: [DatabaseConnectionProfile] = []
    public var databaseURL: URL?
    public var tables: [TableSummary] = []
    public var graph: SchemaGraph = .empty
    public var schemaSidecar: SchemaSidecar = .empty
    public var leftPane = WorkspacePaneState(kind: .schema)
    public var rightPane = WorkspacePaneState(kind: .tables)
    public var activePaneSide: WorkspacePaneSide = .right
    public var maximizedPaneSide: WorkspacePaneSide?
    public var selectedGraphNodeID: String?
    public var selectedGraphNodeIDs: Set<String> = []
    public var expandedGraphNodeIDs: Set<String> = []
    public var floatingDetailsCardTableID: String?
    public var floatingDetailsCardPosition: CGPoint?
    public var showAllGraphTableCards = false
    public var showClusterHalos = true
    public var openTabs: [TableTabModel] = []
    public var activeTabID: UUID?
    public var isRefreshing = false
    public var isTablePickerPresented = false
    public var isProfileManagerPresented = false
    public var isCreateTablePresented = false
    public var isAlterTablePresented = false
    public var isSkillsPresented = false
    // Graph viewport state — shared so the minimap can be rendered outside the pane clip boundary
    public var graphZoom: CGFloat = 1.0
    public var graphPan: CGSize = .zero
    public var presentedError: SQLiteUserError?

    public let graphLayout = GraphLayoutModel()
    public var queryWorkspace: QueryWorkspaceModel

    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var tableDescriptors: [String: EditableTableDescriptor] = [:]
    private static let recentDatabaseStorageKey = "SQLiteGraphStudio.recent-databases"
    private static let profileStorageKey = "SQLiteGraphStudio.connection-profiles"
    private static let allowedDatabaseExtensions: Set<String> = [
        "sqlite",
        "sqlite3",
        "db",
        "sqlite-db",
        "sqlitedb",
    ]
    private static let maxRecentDatabaseCount = 6

    public init(
        databaseService: DatabaseService = DatabaseService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.databaseService = databaseService
        self.userDefaults = userDefaults
        self.queryWorkspace = QueryWorkspaceModel(
            databaseService: databaseService,
            userDefaults: userDefaults
        )
        self.recentDatabaseURLs = Self.loadRecentDatabaseURLs(from: userDefaults)
        self.connectionProfiles = Self.loadConnectionProfiles(from: userDefaults)
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
            rememberRecentDatabase(url)
            StudioLog.ui.info("Loaded database session for \(url.lastPathComponent, privacy: .public)")
        } catch {
            presentedError = SQLiteUserError.from(error)
        }
    }

    public func openRecentDatabase(_ url: URL) {
        guard recentDatabaseURLs.contains(url.standardizedFileURL) else { return }
        Task { await openDatabase(url: url) }
    }

    public func closeDatabase() {
        Task {
            await databaseService.close()
        }
        databaseURL = nil
        tables = []
        graph = .empty
        schemaSidecar = .empty
        leftPane = WorkspacePaneState(kind: .schema)
        rightPane = WorkspacePaneState(kind: .tables)
        activePaneSide = .right
        maximizedPaneSide = nil
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        openTabs = []

        activeTabID = nil
        tableDescriptors = [:]
        graphLayout.setClusterHints([:])
        graphLayout.reset(for: .empty)
        queryWorkspace.reset()
    }

    /// Re-reads `<db>.sqlite.studio.json` from disk and updates cluster hints. Does **not**
    /// touch node positions — call alongside a layout rebuild to actually re-position nodes.
    public func reloadSchemaSidecarFromDisk() {
        guard let databaseURL else { return }
        let sidecar = SchemaSidecarStore.load(for: databaseURL)
        schemaSidecar = sidecar
        graphLayout.setClusterHints(sidecar.nodeToClusterGroup)
    }

    /// Removes the cached layout snapshot for the open database from UserDefaults so the
    /// next layout pass regenerates fresh from cluster hints instead of restoring stale
    /// at-origin positions left over from earlier app builds.
    public func clearPersistedGraphLayout() {
        guard let databaseURL else { return }
        userDefaults.removeObject(forKey: graphLayoutStorageKey(for: databaseURL))
    }

    public func tableDescription(for tableName: String) -> String? {
        let raw = tableDescriptors[tableName]?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    public func columnDescription(for tableName: String, column columnName: String) -> String? {
        let raw = tableDescriptors[tableName]?.columnDescriptions[columnName]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    public var hasAnyDescriptions: Bool {
        tableDescriptors.values.contains { descriptor in
            descriptor.description?.isEmpty == false || !descriptor.columnDescriptions.isEmpty
        }
    }

    public func clusterLabel(for tableName: String) -> String? {
        guard let groupID = schemaSidecar.nodeToClusterGroup[tableName] else { return nil }
        return schemaSidecar.clusters.first(where: { $0.id == groupID })?.label ?? groupID
    }

    public func refreshSchema() {
        guard let databaseURL else { return }
        persistCurrentGraphLayout()
        Task { await openDatabase(url: databaseURL) }
    }

    public func showTablePicker() {
        guard !tables.isEmpty else { return }
        isTablePickerPresented = true
    }

    public func dismissTablePicker() {
        isTablePickerPresented = false
    }

    public func showProfileManager() {
        isProfileManagerPresented = true
    }

    public func dismissProfileManager() {
        isProfileManagerPresented = false
    }

    public func showCreateTable() {
        guard hasOpenDatabase else { return }
        isCreateTablePresented = true
    }

    public func dismissCreateTable() {
        isCreateTablePresented = false
    }

    public func showAlterTable() {
        guard activeTab != nil else { return }
        isAlterTablePresented = true
    }

    public func dismissAlterTable() {
        isAlterTablePresented = false
    }

    public func showSkills() { isSkillsPresented = true }
    public func dismissSkills() { isSkillsPresented = false }

    public var skillsDirectory: URL? {
        guard let dbDir = databaseURL?.deletingLastPathComponent() else { return nil }
        return StudioSkills.gitRoot(from: dbDir) ?? dbDir
    }

    public var skillsInstalled: Bool {
        guard let dir = skillsDirectory else { return false }
        return StudioSkills.areInstalled(in: dir)
    }

    public func installSkills() {
        guard let dir = skillsDirectory else { return }
        try? StudioSkills.install(StudioSkills.all, to: dir)
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
            selectedGraphNodeIDs = [nodeID]
            StudioLog.ui.debug("Selected graph node: \(nodeID, privacy: .public)")
        } else {
            selectedGraphNodeIDs = []
        }
    }
    
    public func addToGraphSelection(_ nodeID: String) {
        guard graph.contains(nodeID: nodeID) else { return }
        selectedGraphNodeIDs.insert(nodeID)
        selectedGraphNodeID = nodeID
    }
    
    public func setGraphSelection(_ nodeIDs: Set<String>) {
        selectedGraphNodeIDs = nodeIDs.filter { graph.contains(nodeID: $0) }
        selectedGraphNodeID = selectedGraphNodeIDs.first
    }
    
    public func clearGraphSelection() {
        selectedGraphNodeID = nil
        selectedGraphNodeIDs = []
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
        if isPresented, !showAllGraphTableCards {
            persistCurrentGraphLayout()
        }
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

    public func restoreCompactGraphLayoutForCurrentDatabase() {
        guard let databaseURL else { return }
        restorePersistedGraphLayoutIfAvailable(for: databaseURL, graph: graph)
    }

    public func openSelectedGraphNode() {
        guard let selectedGraphNodeID else { return }
        openTable(named: selectedGraphNodeID)
    }

    public func openQuery(
        title: String? = nil,
        sqlText: String,
        runImmediately: Bool = false,
        isSaved: Bool = false
    ) {
        ensurePaneVisible(.query)
        if let queryPaneSide = side(containing: .query) {
            activePaneSide = queryPaneSide
        }

        queryWorkspace.createQuery(
            title: title,
            sqlText: sqlText,
            activate: true,
            runImmediately: runImmediately,
            isSaved: isSaved
        )
    }

    public func runTopRowsQuery(for tableName: String) {
        guard tableDescriptors[tableName] != nil else {
            presentedError = SQLiteUserError(kind: .notFound, message: "Table \(tableName) was not found.")
            return
        }

        openQuery(
            title: "\(tableName) Top 10",
            sqlText: """
            SELECT *
            FROM \(quoteIdentifier(tableName))
            LIMIT 10;
            """,
            runImmediately: true
        )
    }

    public func openConnectionProfile(_ profile: DatabaseConnectionProfile) {
        let url = resolvedURL(for: profile)
        Task { await openDatabase(url: url) }
        touchConnectionProfile(id: profile.id)
    }

    public func saveCurrentConnectionProfile(name rawName: String? = nil) {
        guard let databaseURL else { return }
        let normalizedURL = databaseURL.standardizedFileURL
        let fallbackName = normalizedURL.deletingPathExtension().lastPathComponent
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawName!.trimmingCharacters(in: .whitespacesAndNewlines) : fallbackName
        let bookmarkData = try? normalizedURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)

        if let existingIndex = connectionProfiles.firstIndex(where: { $0.url == normalizedURL }) {
            connectionProfiles[existingIndex].name = name
            connectionProfiles[existingIndex].bookmarkData = bookmarkData
            connectionProfiles[existingIndex].lastOpenedAt = Date()
        } else {
            connectionProfiles.insert(
                DatabaseConnectionProfile(
                    name: name,
                    filePath: normalizedURL.path,
                    bookmarkData: bookmarkData,
                    lastOpenedAt: Date()
                ),
                at: 0
            )
        }
        persistConnectionProfiles()
    }

    public func renameConnectionProfile(_ profile: DatabaseConnectionProfile, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = connectionProfiles.firstIndex(where: { $0.id == profile.id })
        else {
            return
        }

        connectionProfiles[index].name = name
        persistConnectionProfiles()
    }

    public func deleteConnectionProfile(_ profile: DatabaseConnectionProfile) {
        connectionProfiles.removeAll { $0.id == profile.id }
        persistConnectionProfiles()
    }

    public func createTable(_ draft: TableCreateDraft) {
        Task {
            do {
                try await databaseService.createTable(draft)
                dismissCreateTable()
                refreshSchema()
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func renameActiveTable(to newName: String) {
        guard let descriptor = activeTab?.descriptor else { return }
        Task {
            do {
                try await databaseService.renameTable(from: descriptor.name, to: newName)
                dismissAlterTable()
                refreshSchema()
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func addColumnToActiveTable(_ draft: TableColumnDraft) {
        guard let descriptor = activeTab?.descriptor else { return }
        Task {
            do {
                try await databaseService.addColumn(draft, to: descriptor)
                dismissAlterTable()
                refreshSchema()
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func renameColumnInActiveTable(from oldName: String, to newName: String) {
        guard let descriptor = activeTab?.descriptor else { return }
        Task {
            do {
                try await databaseService.renameColumn(from: oldName, to: newName, in: descriptor)
                dismissAlterTable()
                refreshSchema()
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func dropColumnFromActiveTable(_ columnName: String) {
        guard let tab = activeTab else { return }
        Task {
            do {
                try await tab.dropColumn(columnName)
                dismissAlterTable()
                refreshSchema()
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func createTableSQLPreview(for draft: TableCreateDraft) -> String {
        (try? databaseService.makeCreateTableSQL(draft)) ?? ""
    }

    public func exportActiveTableRows(format: DataTransferFormat) {
        guard let activeTab else { return }
        Task {
            do {
                let text = try await databaseService.serializeTableRows(
                    descriptor: activeTab.descriptor,
                    rows: activeTab.chunk.rows,
                    format: format
                )
                try presentExportPanel(defaultName: activeTab.title, format: format, text: text)
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func exportActiveQueryResult(format: DataTransferFormat) {
        guard let activeQuery = queryWorkspace.activeQuery else { return }
        Task {
            do {
                let text = try await databaseService.serializeQueryResult(activeQuery.result, format: format)
                try presentExportPanel(defaultName: activeQuery.title, format: format, text: text)
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    public func importRowsIntoActiveTable(format: DataTransferFormat) {
        guard let activeTab else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let result = try await databaseService.importRows(into: activeTab.descriptor, text: text, format: format)
                activeTab.inlineErrorMessage = result.messages.first
                await activeTab.reload()
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        }
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
    
    public func toggleMaximizePane(_ side: WorkspacePaneSide) {
        if maximizedPaneSide == side {
            maximizedPaneSide = nil
        } else {
            maximizedPaneSide = side
        }
    }
    
    public func isMaximized(_ side: WorkspacePaneSide) -> Bool {
        maximizedPaneSide == side
    }
    
    public func exitMaximizedMode() {
        maximizedPaneSide = nil
    }

    private func rememberRecentDatabase(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        var urls = recentDatabaseURLs.filter { $0 != normalizedURL }
        urls.insert(normalizedURL, at: 0)
        recentDatabaseURLs = Array(urls.prefix(Self.maxRecentDatabaseCount))
        userDefaults.set(recentDatabaseURLs.map(\.path), forKey: Self.recentDatabaseStorageKey)
    }

    private func touchConnectionProfile(id: UUID) {
        guard let index = connectionProfiles.firstIndex(where: { $0.id == id }) else { return }
        connectionProfiles[index].lastOpenedAt = Date()
        persistConnectionProfiles()
    }

    private func persistConnectionProfiles() {
        guard let data = try? JSONEncoder().encode(connectionProfiles) else { return }
        userDefaults.set(data, forKey: Self.profileStorageKey)
    }

    private static func loadConnectionProfiles(from userDefaults: UserDefaults) -> [DatabaseConnectionProfile] {
        guard let data = userDefaults.data(forKey: profileStorageKey),
              let profiles = try? JSONDecoder().decode([DatabaseConnectionProfile].self, from: data)
        else {
            return []
        }

        return profiles.filter { profile in
            FileManager.default.fileExists(atPath: profile.filePath)
        }
    }

    private func resolvedURL(for profile: DatabaseConnectionProfile) -> URL {
        guard let bookmarkData = profile.bookmarkData else {
            return profile.url
        }

        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url.standardizedFileURL
        }

        return profile.url
    }

    private func presentExportPanel(defaultName: String, format: DataTransferFormat, text: String) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func loadRecentDatabaseURLs(from userDefaults: UserDefaults) -> [URL] {
        let paths = userDefaults.stringArray(forKey: recentDatabaseStorageKey) ?? []
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard allowedDatabaseExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return nil
            }
            return url
        }
    }

    private func apply(snapshot: CatalogSnapshot, url: URL) {
        databaseURL = url
        tableDescriptors = Dictionary(uniqueKeysWithValues: snapshot.descriptors.map { ($0.name, $0) })
        tables = snapshot.descriptors.map(\.summary)
        graph = snapshot.graph
        let sidecar = SchemaSidecarStore.load(for: url)
        schemaSidecar = sidecar
        graphLayout.setClusterHints(sidecar.nodeToClusterGroup)
        graphLayout.reset(for: snapshot.graph)
        restorePersistedGraphLayoutIfAvailable(for: url, graph: snapshot.graph)
        activePaneSide = .right
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = snapshot.graph.nodes.count < 14
        queryWorkspace.loadSavedQueries(for: url)
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
