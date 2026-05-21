import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

public struct RefreshToast: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

public enum StoryReadAloudStatus: Sendable, Equatable {
    case idle
    case installRequired
    case installing(String)
    case preparing(String)
    case generating
    case speaking
    case failed(String)

    public var displayText: String? {
        switch self {
        case .idle:
            return nil
        case .installRequired:
            return "Install Kokoro"
        case .installing(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Installing Kokoro" : message
        case .preparing(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing audio" : message
        case .generating:
            return "Preparing voice"
        case .speaking:
            return "Reading"
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 96 else { return trimmed }
            return "\(trimmed.prefix(93))..."
        }
    }

    public var isBusy: Bool {
        switch self {
        case .installing, .preparing, .generating:
            return true
        case .idle, .installRequired, .speaking, .failed:
            return false
        }
    }

    public var requiresInstall: Bool {
        if case .installRequired = self {
            return true
        }
        return false
    }
}

public struct StoryPlaybackOverlayState: Sendable, Equatable {
    public let title: String
    public let clusterLabel: String?
    public let clusterColorHex: String?
    public let userStoryText: String?
    public let actor: String?
    public let goal: String?
    public let benefit: String?
    public let conversation: [String]
    public let acceptanceCriteria: [String]
    public let displayedText: String
    public let acceptanceText: String?
    public let index: Int
    public let playbackCount: Int
    public let isPaused: Bool
    public let isReadAloudEnabled: Bool
    public let readAloudStatus: StoryReadAloudStatus
    public let isReadAloudBusy: Bool
    public let canGoBackward: Bool
    public let canGoForward: Bool

    public init(
        title: String,
        clusterLabel: String? = nil,
        clusterColorHex: String? = nil,
        userStoryText: String?,
        actor: String? = nil,
        goal: String? = nil,
        benefit: String? = nil,
        conversation: [String] = [],
        acceptanceCriteria: [String] = [],
        displayedText: String,
        acceptanceText: String?,
        index: Int,
        playbackCount: Int,
        isPaused: Bool,
        isReadAloudEnabled: Bool = false,
        readAloudStatus: StoryReadAloudStatus = .idle,
        isReadAloudBusy: Bool = false,
        canGoBackward: Bool,
        canGoForward: Bool
    ) {
        self.title = title
        self.clusterLabel = clusterLabel
        self.clusterColorHex = clusterColorHex
        self.userStoryText = userStoryText
        self.actor = actor
        self.goal = goal
        self.benefit = benefit
        self.conversation = conversation
        self.acceptanceCriteria = acceptanceCriteria
        self.displayedText = displayedText
        self.acceptanceText = acceptanceText
        self.index = index
        self.playbackCount = playbackCount
        self.isPaused = isPaused
        self.isReadAloudEnabled = isReadAloudEnabled
        self.readAloudStatus = readAloudStatus
        self.isReadAloudBusy = isReadAloudBusy
        self.canGoBackward = canGoBackward
        self.canGoForward = canGoForward
    }
}

public struct StoryPlaybackCommand: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case previous
        case togglePause
        case toggleReadAloud
        case installReadAloud
        case next
        case stop
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

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
    public var showStoryCardsInGraph = false
    public var showOnlyStoryCardsInGraph = false
    public var openTabs: [TableTabModel] = []
    public var activeTabID: UUID?
    public var isRefreshing = false
    public var isTablePickerPresented = false
    public var isProfileManagerPresented = false
    public var isCreateTablePresented = false
    public var isAlterTablePresented = false
    public var isSkillsPresented = false
    public var refreshToast: RefreshToast?
    public var storyPlaybackOverlay: StoryPlaybackOverlayState?
    /// Beat narration shown on the playback card; updated during typing without rebuilding overlay state.
    public var storyPlaybackDisplayedText: String = ""
    public var isStoryReadAloudEnabled = false
    public var storyReadAloudStatus: StoryReadAloudStatus = .idle
    public var isStoryReadAloudBusy = false
    public var storyPlaybackCardOffset: CGSize = .zero
    public var storyPlaybackCommand: StoryPlaybackCommand?
    // Graph viewport state — shared so the minimap can be rendered outside the pane clip boundary
    public var graphZoom: CGFloat = 1.0
    public var graphPan: CGSize = .zero
    public var presentedError: SQLiteUserError?

    public let graphLayout = GraphLayoutModel()
    public var queryWorkspace: QueryWorkspaceModel

    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var tableDescriptors: [String: EditableTableDescriptor] = [:]
    private var pinnedStoryGraphPositionsByMode: [String: [String: CGPoint]] = [:]
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
        await openDatabase(url: url, changeBaseline: nil)
    }

    private func openDatabase(url: URL, changeBaseline: SchemaRefreshSnapshot?) async {
        isRefreshing = true
        presentedError = nil
        defer { isRefreshing = false }

        do {
            try await databaseService.open(url: url)
            let snapshot = try await databaseService.loadCatalogSnapshot()
            apply(snapshot: snapshot, url: url)
            if let changeBaseline {
                refreshToast = Self.refreshSummary(
                    before: changeBaseline,
                    after: SchemaRefreshSnapshot(
                        descriptors: tableDescriptors,
                        graph: graph,
                        sidecar: schemaSidecar
                    )
                ).map { RefreshToast(message: $0) }
            }
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
        showStoryCardsInGraph = false
        showOnlyStoryCardsInGraph = false
        openTabs = []

        activeTabID = nil
        tableDescriptors = [:]
        graphLayout.setClusterHints([:])
        graphLayout.reset(for: .empty)
        pinnedStoryGraphPositionsByMode = [:]
        queryWorkspace.reset()
        refreshToast = nil
    }

    /// Re-reads `<db>.sqlite.studio.json` from disk and updates sidecar descriptions and
    /// cluster hints. Does **not** touch node positions — call alongside a layout rebuild to
    /// actually re-position nodes.
    public func reloadSchemaSidecarFromDisk() {
        guard let databaseURL else { return }
        let before = schemaSidecar
        let sidecar = SchemaSidecarStore.load(for: databaseURL)
        schemaSidecar = sidecar
        graphLayout.setClusterHints(sidecar.nodeToClusterGroup)
        refreshToast = Self.sidecarSummary(before: before, after: sidecar)
            .map { RefreshToast(message: $0) }
    }

    /// Removes the cached layout snapshot for the open database from UserDefaults so the
    /// next layout pass regenerates fresh from cluster hints instead of restoring stale
    /// at-origin positions left over from earlier app builds.
    public func clearPersistedGraphLayout() {
        guard let databaseURL else { return }
        userDefaults.removeObject(forKey: graphLayoutStorageKey(for: databaseURL))
    }

    /// Removes cached story-card positions so the next layout pass recomputes cluster placement.
    public func clearPersistedStoryGraphLayout() {
        guard let databaseURL else { return }
        userDefaults.removeObject(forKey: storyGraphLayoutStorageKey(for: databaseURL))
        pinnedStoryGraphPositionsByMode = [:]
    }

    public func tableDescription(for tableName: String) -> String? {
        let raw = schemaSidecar.tables[tableName]?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    public func columnDescription(for tableName: String, column columnName: String) -> String? {
        let raw = schemaSidecar.tables[tableName]?.columns[columnName]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    public func descriptionForQueryResultColumn(_ columnName: String) -> String? {
        let trimmed = columnName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let separatorIndex = trimmed.firstIndex(of: ".") {
            let tableName = String(trimmed[..<separatorIndex])
            let fieldName = String(trimmed[trimmed.index(after: separatorIndex)...])
            if let description = columnDescription(for: tableName, column: fieldName) {
                return description
            }
            if let description = tableDescription(for: tableName) {
                return description
            }
        }

        if let description = tableDescription(for: trimmed) {
            return description
        }

        let columnMatches = schemaSidecar.tables.compactMap { tableName, table in
            table.columns[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (tableName, table.columns[trimmed]!)
                : nil
        }

        guard columnMatches.count == 1, let match = columnMatches.first else {
            return nil
        }

        return "\(match.0).\(trimmed): \(match.1)"
    }

    public var hasAnyDescriptions: Bool {
        schemaSidecar.tables.values.contains { table in
            table.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || table.columns.values.contains {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
    }

    public var stories: [SchemaSidecar.Story] {
        schemaSidecar.stories.sorted { lhs, rhs in
            lhs.createdAt.localizedStandardCompare(rhs.createdAt) == .orderedDescending
        }
    }

    public func clusterLabel(for tableName: String) -> String? {
        guard let groupID = schemaSidecar.nodeToClusterGroup[tableName] else { return nil }
        return schemaSidecar.clusters.first(where: { $0.id == groupID })?.label ?? groupID
    }

    public func refreshSchema() {
        guard let databaseURL else { return }
        let baseline = SchemaRefreshSnapshot(
            descriptors: tableDescriptors,
            graph: graph,
            sidecar: schemaSidecar
        )
        persistCurrentGraphLayout()
        persistStoryGraphLayout()
        Task { await openDatabase(url: databaseURL, changeBaseline: baseline) }
    }

    public func dismissRefreshToast() {
        refreshToast = nil
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
        return !StudioSkills.hasMissingInstallableSkills(in: dir)
    }

    public func installSkills() {
        guard let dir = skillsDirectory else { return }
        try? StudioSkills.install(StudioSkills.all, to: dir)
    }

    public func installSkill(_ skill: StudioSkill) {
        guard let dir = skillsDirectory else { return }
        try? StudioSkills.install([skill], to: dir)
    }

    public func installSkills(to targetDirectory: StudioSkillDirectoryTarget) {
        guard let dir = skillsDirectory else { return }
        try? StudioSkills.install(StudioSkills.all, to: dir, targetDirectory: targetDirectory)
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

    public func deleteStory(id storyID: String) {
        guard let databaseURL else { return }
        guard schemaSidecar.stories.contains(where: { $0.id == storyID }) else { return }

        let before = schemaSidecar
        var next = schemaSidecar
        next.stories.removeAll { $0.id == storyID }

        do {
            try SchemaSidecarStore.save(next, for: databaseURL)
            schemaSidecar = next
            refreshToast = Self.sidecarSummary(before: before, after: next)
                .map { RefreshToast(message: $0) }
        } catch {
            presentedError = SQLiteUserError(
                kind: .generic,
                message: "Could not update the sidecar file: \(error.localizedDescription)"
            )
        }
    }

    public func persistCurrentGraphLayout() {
        guard let databaseURL, !graph.nodes.isEmpty else { return }
        let snapshot = graphLayout.snapshot(for: graph)
        let persistedLayout = PersistedGraphLayout(snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(persistedLayout) else { return }
        userDefaults.set(data, forKey: graphLayoutStorageKey(for: databaseURL))
    }

    public func pinnedStoryGraphPosition(for storyID: String) -> CGPoint? {
        pinnedStoryGraphPosition(for: storyID, mode: StoryGraphPlacement.layoutMode(for: self))
    }

    public func pinnedStoryGraphPosition(for storyID: String, mode: StoryGraphLayoutMode) -> CGPoint? {
        pinnedStoryGraphPositionsByMode[mode.persistenceKey]?[storyID]
    }

    public func pinStoryGraphPosition(_ storyID: String, at point: CGPoint) {
        pinStoryGraphPosition(storyID, at: point, mode: StoryGraphPlacement.layoutMode(for: self))
    }

    public func pinStoryGraphPosition(_ storyID: String, at point: CGPoint, mode: StoryGraphLayoutMode) {
        let key = mode.persistenceKey
        var positions = pinnedStoryGraphPositionsByMode[key, default: [:]]
        positions[storyID] = point
        pinnedStoryGraphPositionsByMode[key] = positions
    }

    public func persistStoryGraphLayout() {
        guard let databaseURL else { return }
        guard !pinnedStoryGraphPositionsByMode.isEmpty else {
            userDefaults.removeObject(forKey: storyGraphLayoutStorageKey(for: databaseURL))
            return
        }

        let persistedLayout = PersistedStoryGraphLayout(positionsByMode: pinnedStoryGraphPositionsByMode)
        guard let data = try? JSONEncoder().encode(persistedLayout) else { return }
        userDefaults.set(data, forKey: storyGraphLayoutStorageKey(for: databaseURL))
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
        pinnedStoryGraphPositionsByMode = [:]
        restorePersistedGraphLayoutIfAvailable(for: url, graph: snapshot.graph)
        restorePersistedStoryGraphLayoutIfAvailable(for: url)
        activePaneSide = .right
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        showStoryCardsInGraph = false
        showOnlyStoryCardsInGraph = false
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

    private func storyGraphLayoutStorageKey(for url: URL) -> String {
        "SQLiteGraphStudio.story-graph-layout.\(url.path)"
    }

    private func restorePersistedStoryGraphLayoutIfAvailable(for url: URL) {
        guard let data = userDefaults.data(forKey: storyGraphLayoutStorageKey(for: url)),
              let persistedLayout = try? JSONDecoder().decode(PersistedStoryGraphLayout.self, from: data)
        else {
            return
        }

        pinnedStoryGraphPositionsByMode = persistedLayout.cgPointsByMode
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

    private static func refreshSummary(before: SchemaRefreshSnapshot, after: SchemaRefreshSnapshot) -> String? {
        var changes: [String] = []

        let beforeTables = Set(before.descriptors.keys)
        let afterTables = Set(after.descriptors.keys)
        appendCount(afterTables.subtracting(beforeTables).count, label: "table", prefix: "+", to: &changes)
        appendCount(beforeTables.subtracting(afterTables).count, label: "table", prefix: "-", to: &changes)

        var addedColumns = 0
        var removedColumns = 0
        for tableName in beforeTables.intersection(afterTables) {
            let beforeColumns = Set(before.descriptors[tableName]?.columns.map(\.name) ?? [])
            let afterColumns = Set(after.descriptors[tableName]?.columns.map(\.name) ?? [])
            addedColumns += afterColumns.subtracting(beforeColumns).count
            removedColumns += beforeColumns.subtracting(afterColumns).count
        }
        appendCount(addedColumns, label: "col", prefix: "+", to: &changes)
        appendCount(removedColumns, label: "col", prefix: "-", to: &changes)

        let beforeEdges = Set(before.graph.edges.map(\.id))
        let afterEdges = Set(after.graph.edges.map(\.id))
        appendCount(afterEdges.subtracting(beforeEdges).count, label: "relation", prefix: "+", to: &changes)
        appendCount(beforeEdges.subtracting(afterEdges).count, label: "relation", prefix: "-", to: &changes)

        if let sidecarChange = sidecarChangeFragment(before: before.sidecar, after: after.sidecar) {
            changes.append(sidecarChange)
        }

        return formattedRefreshSummary(changes)
    }

    private static func sidecarSummary(before: SchemaSidecar, after: SchemaSidecar) -> String? {
        guard let change = sidecarChangeFragment(before: before, after: after) else { return nil }
        return formattedRefreshSummary([change])
    }

    private static func sidecarChangeFragment(before: SchemaSidecar, after: SchemaSidecar) -> String? {
        guard before != after else { return nil }

        let beforeNoteCount = noteCount(in: before)
        let afterNoteCount = noteCount(in: after)
        let noteDelta = afterNoteCount - beforeNoteCount
        if noteDelta > 0 {
            return "+\(noteDelta) \(pluralized("note", count: noteDelta))"
        }
        if noteDelta < 0 {
            return "\(noteDelta) \(pluralized("note", count: abs(noteDelta)))"
        }

        let clusterDelta = after.clusters.count - before.clusters.count
        if clusterDelta > 0 {
            return "+\(clusterDelta) \(pluralized("cluster", count: clusterDelta))"
        }
        if clusterDelta < 0 {
            return "\(clusterDelta) \(pluralized("cluster", count: abs(clusterDelta)))"
        }

        let storyDelta = after.stories.count - before.stories.count
        if storyDelta > 0 {
            return "+\(storyDelta) \(pluralized("story", count: storyDelta))"
        }
        if storyDelta < 0 {
            return "\(storyDelta) \(pluralized("story", count: abs(storyDelta)))"
        }

        return "notes changed"
    }

    private static func noteCount(in sidecar: SchemaSidecar) -> Int {
        sidecar.tables.values.reduce(0) { count, table in
            let hasTableNote = table.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let columnNoteCount = table.columns.values.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            return count + (hasTableNote ? 1 : 0) + columnNoteCount
        }
    }

    private static func appendCount(_ count: Int, label: String, prefix: String, to changes: inout [String]) {
        guard count > 0 else { return }
        changes.append("\(prefix)\(count) \(pluralized(label, count: count))")
    }

    private static func formattedRefreshSummary(_ changes: [String]) -> String? {
        guard !changes.isEmpty else { return nil }
        return "Updated: " + changes.prefix(4).joined(separator: ", ")
    }

    private static func pluralized(_ label: String, count: Int) -> String {
        count == 1 ? label : "\(label)s"
    }
}

private struct SchemaRefreshSnapshot {
    let descriptors: [String: EditableTableDescriptor]
    let graph: SchemaGraph
    let sidecar: SchemaSidecar
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

private struct PersistedStoryGraphLayout: Codable {
    let positionsByMode: [String: [String: PersistedPoint]]

    init(positionsByMode: [String: [String: CGPoint]]) {
        self.positionsByMode = positionsByMode.mapValues { modePositions in
            modePositions.mapValues(PersistedPoint.init)
        }
    }

    var cgPointsByMode: [String: [String: CGPoint]] {
        positionsByMode.mapValues { modePositions in
            modePositions.mapValues(\.cgPoint)
        }
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
