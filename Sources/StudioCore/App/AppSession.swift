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
    public private(set) var databaseTarget: DatabaseTarget?
    /// The opened SQLite file or PostgreSQL connection document. Connection identity
    /// and database operations use `databaseTarget`, independently of this local URL.
    public var databaseURL: URL?
    public private(set) var databaseCapabilities: DatabaseCapabilities = .none
    public var tables: [TableSummary] = []
    public var graph: SchemaGraph = .empty {
        didSet { graphRevision &+= 1 }
    }
    private(set) var graphRevision = 0
    public private(set) var schemaMetadataState = SchemaMetadataState()
    public var metadataDiagnostics: [String] { schemaMetadataState.diagnostics }

    public var schemaSidecar: SchemaSidecar = .empty
    public private(set) var graphGrouping: GraphGrouping = .empty {
        didSet { graphGroupingRevision &+= 1 }
    }
    private(set) var graphGroupingRevision = 0
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
    // Layout positions can be restored before this session has fitted a camera.
    var initializedGraphViewportDocument: String?
    public var presentedError: SQLiteUserError?

    public let records: RecordWorkspace

    public let graphLayout = GraphLayoutModel()
    public var queryWorkspace: QueryWorkspaceModel

    private var openGeneration = UUID()
    private var pendingDatabaseClose: Task<Void, Never>?
    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var tableDescriptors: [String: EditableTableDescriptor] = [:]
    private var pinnedStoryGraphPositionsByMode: [String: [String: CGPoint]] = [:]
    private static let recentDatabaseStorageKey = "SQLiteGraphStudio.recent-databases"
    private static let graphLayoutStorageVersion = 2
    private static let allowedDatabaseExtensions: Set<String> = Set([
        "sqlite",
        "sqlite3",
        "db",
        "sqlite-db",
        "sqlitedb",
    ]).union(PostgresConnectionDocument.supportedFileExtensions)
    private static let maxRecentDatabaseCount = 6

    public init(
        databaseService: DatabaseService = DatabaseService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.records = RecordWorkspace(mappingLoader: { mapping, root, direction, offset, catalog in
            try await RecordGraphMappingAccess.load(mapping: mapping, root: root, direction: direction, offset: offset, catalog: catalog, database: databaseService)
        }) { record, relationship, direction, offset, limit in
            try await databaseService.fetchRelated(record: record, relationship: relationship, direction: direction, offset: offset, limit: limit)
        }
        self.databaseService = databaseService
        self.userDefaults = userDefaults
        self.queryWorkspace = QueryWorkspaceModel(
            databaseService: databaseService,
            userDefaults: userDefaults
        )
        self.recentDatabaseURLs = Self.loadRecentDatabaseURLs(from: userDefaults)
    }

    func configureRecordMappings(_ sidecar: SchemaSidecar) {
        let previousMappings = records.mappings
        records.mappings = []; records.mappingValidationMessages = []
        var seen = Set<String>()
        for mapping in sidecar.recordGraphMappings {
            do {
                guard seen.insert(mapping.id).inserted else {
                    records.mappingValidationMessages.append("Duplicate graph mapping ID: \(mapping.id)"); continue
                }
                _ = try RecordGraphMappingAccess.validate(mapping: mapping, catalog: records.catalog)
                records.mappings.append(mapping)
            } catch { records.mappingValidationMessages.append("\(mapping.id): \(error.localizedDescription)") }
        }
        if records.mappings != previousMappings { records.reset() }
    }

    public func inspectRecord(in tab: TableTabModel, row: Int) {
        guard let loaded = tab.row(at: row) else { return }
        do {
            let record = try RecordAccess.snapshot(
                descriptor: tab.descriptor,
                columns: tab.descriptor.columns.map { QueryResultColumn(name: $0.name, typeLabel: $0.typeLabel) },
                values: loaded.values, rowIdentity: loaded.identity
            )
            records.open(record)
            records.originLabel = "\(tab.title) · row \(row + 1)"
        } catch { presentedError = SQLiteUserError.from(error) }
    }

    public func inspectQueryRecord(result: QueryResult, row: QueryResultRow, executedSQL: String? = nil) {
        do {
            let descriptor = RecordQueryOrigin.descriptor(executedSQL: executedSQL, result: result, catalog: records.catalog)
            records.open(try RecordAccess.snapshot(descriptor: descriptor, columns: result.columns, values: row.values))
            records.originLabel = "Query result · row \(row.id + 1)"
        } catch { presentedError = SQLiteUserError.from(error) }
    }

    public var activeTab: TableTabModel? {
        openTabs.first(where: { $0.id == activeTabID }) ?? openTabs.first
    }

    public var hasOpenDatabase: Bool {
        databaseTarget != nil
    }

    public var databaseDisplayName: String {
        databaseTarget?.displayName ?? "No Database"
    }

    public var isPostgreSQL: Bool {
        databaseTarget?.isPostgres ?? false
    }

    public func presentOpenDatabasePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        let documentFilter = DatabaseDocumentOpenPanelDelegate(extensions: ["sqlite", "sqlite3", "db", "sqlite-db", "sqlitedb"])
        panel.delegate = documentFilter
        panel.prompt = "Open Database"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openDatabase(url: url) }
    }

    public func openDatabase(url: URL) async {
        await openDatabase(url: url, changeBaseline: nil)
    }

    private func openDatabase(url: URL, changeBaseline: SchemaRefreshSnapshot?) async {
        records.reset()
        let generation = UUID()
        openGeneration = generation
        queryWorkspace.stopAll()
        cancelExport()

        isRefreshing = true
        presentedError = nil
        defer { if openGeneration == generation { isRefreshing = false } }

        do {
            await pendingDatabaseClose?.value
            guard openGeneration == generation else { return }
            try await databaseService.open(url: url)
            guard openGeneration == generation else { return }
            let snapshot = try await databaseService.loadCatalogSnapshot()
            guard openGeneration == generation else { return }
            apply(snapshot: snapshot, target: .sqlite(url))
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
            StudioLog.ui.info("Loaded database session for \(url.lastPathComponent, privacy: .public)")
        } catch {
            guard openGeneration == generation else { return }
            presentedError = SQLiteUserError.from(error)
        }
    }

    public func presentOpenPostgreSQLDocumentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // These are app-owned JSON documents, not a system-provided UTI. Use
        // a data filter plus the delegate's explicit extension check instead
        // of relying on dynamic UTI inference for the custom suffixes.
        panel.allowedContentTypes = [.data]
        let documentFilter = DatabaseDocumentOpenPanelDelegate(extensions: PostgresConnectionDocument.supportedFileExtensions)
        panel.delegate = documentFilter
        panel.prompt = "Open PostgreSQL Document"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openPostgreSQLDocument(url: url) }
    }

    public func openDocument(url: URL) async {
        if PostgresConnectionDocument.supportedFileExtensions.contains(url.pathExtension.lowercased()) {
            await openPostgreSQLDocument(url: url)
        } else {
            await openDatabase(url: url)
        }
    }

    public func openPostgreSQLDocument(url: URL) async {
        records.reset()
        let generation = UUID()
        openGeneration = generation
        queryWorkspace.stopAll()
        cancelExport()

        isRefreshing = true
        presentedError = nil
        defer { if openGeneration == generation { isRefreshing = false } }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(PostgresConnectionDocument.self, from: data)
            await pendingDatabaseClose?.value
            guard openGeneration == generation else { return }
            try await databaseService.open(postgres: document.configuration)
            guard openGeneration == generation else { return }
            let snapshot = try await databaseService.loadCatalogSnapshot()
            guard openGeneration == generation else { return }
            apply(snapshot: snapshot, target: .postgres(document.configuration), documentURL: url)
            databaseCapabilities = .postgresReadOnly
            StudioLog.ui.info(
                "Loaded PostgreSQL document \(url.lastPathComponent, privacy: .public) for \(document.configuration.host, privacy: .public):\(document.configuration.port, privacy: .public)/\(document.configuration.database, privacy: .public)"
            )
        } catch {
            guard openGeneration == generation else { return }
            presentedError = SQLiteUserError.from(error)
        }
    }

    public func openRecentDatabase(_ url: URL) {
        guard recentDatabaseURLs.contains(url.standardizedFileURL) else { return }
        Task { await openDocument(url: url) }
    }

    public func closeDatabase() {
        records.reset()
        openGeneration = UUID()
        isRefreshing = false
        queryWorkspace.stopAll()
        cancelExport()
        let previousClose = pendingDatabaseClose
        pendingDatabaseClose = Task {
            await previousClose?.value
            await databaseService.close()
        }
        databaseTarget = nil
        databaseURL = nil
        initializedGraphViewportDocument = nil
        databaseCapabilities = .none
        isRefreshing = false
        isTablePickerPresented = false
        isCreateTablePresented = false
        isAlterTablePresented = false
        isSkillsPresented = false
        tables = []
        graph = .empty
        schemaSidecar = .empty
        graphGrouping = .empty
        schemaMetadataState = SchemaMetadataState()
        leftPane = WorkspacePaneState(kind: .schema)
        rightPane = WorkspacePaneState(kind: .tables)
        activePaneSide = .right
        maximizedPaneSide = nil
        selectedGraphNodeID = nil
        selectedGraphNodeIDs = []
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

    /// Re-reads `<document>.studio.json` from disk and updates sidecar descriptions and
    /// cluster hints. Does **not** touch node positions — call alongside a layout rebuild to
    /// actually re-position nodes.
    public func reloadSchemaSidecarFromDisk() {
        guard hasOpenDatabase, let databaseURL else { return }
        let before = schemaSidecar
        schemaMetadataState.reload(for: databaseURL, descriptors: Array(tableDescriptors.values))
        let sidecar = schemaMetadataState.sidecar
        schemaSidecar = sidecar
        configureRecordMappings(sidecar)
        updateGraphGrouping()
        refreshToast = Self.sidecarSummary(before: before, after: sidecar)
            .map { RefreshToast(message: $0) }
    }

    /// Removes the cached layout snapshot for the open database from UserDefaults so the
    /// next layout pass regenerates fresh from cluster hints instead of restoring stale
    /// at-origin positions left over from earlier app builds.
    public func clearPersistedGraphLayout() {
        guard let target = databaseTarget else { return }
        userDefaults.removeObject(forKey: graphLayoutStorageKey(for: target))
    }

    /// Removes cached story-card positions so the next layout pass recomputes cluster placement.
    public func clearPersistedStoryGraphLayout() {
        guard let target = databaseTarget else { return }
        userDefaults.removeObject(forKey: storyGraphLayoutStorageKey(for: target))
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

        let knownTableNames = Set(tableDescriptors.keys).union(schemaSidecar.tables.keys)
        if knownTableNames.contains(trimmed) {
            return tableDescription(for: trimmed)
        }

        // A PostgreSQL table ID is already schema-qualified, and both table and
        // column names may contain dots. Match the most specific known table ID.
        if let tableName = knownTableNames
            .filter({ trimmed.hasPrefix($0 + ".") })
            .max(by: { $0.count < $1.count }) {
            let fieldName = String(trimmed.dropFirst(tableName.count + 1))
            return columnDescription(for: tableName, column: fieldName)
                ?? tableDescription(for: tableName)
        }

        let columnMatches = schemaSidecar.tables.compactMap { tableName, table in
            guard let description = table.columns[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else { return nil as (String, String)? }
            return (tableName, description)
        }

        guard columnMatches.count == 1, let match = columnMatches.first else {
            return nil
        }

        // SQLite keeps its existing unique-note fallback. PostgreSQL also verifies
        // catalog ownership so an unqualified alias cannot claim another schema's column.
        if isPostgreSQL, !tableDescriptors.isEmpty {
            let catalogMatches = tableDescriptors.values.filter { descriptor in
                descriptor.columns.contains { $0.name == trimmed }
            }
            guard catalogMatches.count == 1, catalogMatches.first?.name == match.0 else { return nil }
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
        graphGrouping.group(for: tableName)?.label
    }

    public func clusterColorHex(for tableName: String) -> String? {
        graphGrouping.group(for: tableName)?.colorHex
    }

    public func refreshSchema() {
        guard let target = databaseTarget else { return }
        let baseline = SchemaRefreshSnapshot(
            descriptors: tableDescriptors,
            graph: graph,
            sidecar: schemaSidecar
        )
        persistCurrentGraphLayout()
        persistStoryGraphLayout()
        switch target {
        case .sqlite(let databaseURL):
            Task { await openDatabase(url: databaseURL, changeBaseline: baseline) }
        case .postgres:
            let generation = openGeneration
            let documentURL = databaseURL
            Task {
                guard openGeneration == generation, databaseTarget == target, databaseURL == documentURL else { return }
                isRefreshing = true
                defer {
                    if openGeneration == generation, databaseTarget == target, databaseURL == documentURL {
                        isRefreshing = false
                    }
                }
                do {
                    let snapshot = try await databaseService.loadCatalogSnapshot()
                    guard openGeneration == generation, databaseTarget == target, databaseURL == documentURL else { return }
                    apply(snapshot: snapshot, target: target, documentURL: documentURL)
                    refreshToast = Self.refreshSummary(
                        before: baseline,
                        after: SchemaRefreshSnapshot(
                            descriptors: tableDescriptors,
                            graph: graph,
                            sidecar: schemaSidecar
                        )
                    ).map { RefreshToast(message: $0) }
                } catch {
                    guard openGeneration == generation, databaseTarget == target, databaseURL == documentURL else { return }
                    presentedError = SQLiteUserError.from(error)
                }
            }
        }
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

    public func showCreateTable() {
        guard !isRefreshing, hasOpenDatabase, databaseCapabilities.canCreateTable else { return }
        isCreateTablePresented = true
    }

    public func dismissCreateTable() {
        isCreateTablePresented = false
    }

    public func showAlterTable() {
        guard !isRefreshing, activeTab != nil, databaseCapabilities.canAlterSchema else { return }
        isAlterTablePresented = true
    }

    public func dismissAlterTable() {
        isAlterTablePresented = false
    }

    public func showSkills() {
        guard databaseCapabilities.supportsAIWorkspace else { return }
        isSkillsPresented = true
    }
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
        let validIDs = nodeIDs.filter { graph.contains(nodeID: $0) }
        guard validIDs != selectedGraphNodeIDs else { return }
        selectedGraphNodeIDs = validIDs
        if selectedGraphNodeID.map({ validIDs.contains($0) }) != true {
            selectedGraphNodeID = validIDs.min()
        }
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
        guard hasOpenDatabase, let databaseURL else { return }
        guard schemaSidecar.stories.contains(where: { $0.id == storyID }) else { return }
        if case .failed(let error) = schemaMetadataState.status {
            presentedError = DatabaseUserError(kind: .invalidInput, message: error.localizedDescription + " Reload valid metadata before changing stories.")
            return
        }

        let before = schemaSidecar
        var next = schemaSidecar
        next.stories.removeAll { $0.id == storyID }

        do {
            try SchemaSidecarStore.save(next, for: databaseURL)
            schemaSidecar = next
            schemaMetadataState.reload(for: databaseURL, descriptors: Array(tableDescriptors.values))
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
        guard let target = databaseTarget, !graph.nodes.isEmpty else { return }
        let snapshot = graphLayout.snapshot(for: graph)
        let persistedLayout = PersistedGraphLayout(snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(persistedLayout) else { return }
        userDefaults.set(data, forKey: graphLayoutStorageKey(for: target))
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
        guard let target = databaseTarget else { return }
        guard !pinnedStoryGraphPositionsByMode.isEmpty else {
            userDefaults.removeObject(forKey: storyGraphLayoutStorageKey(for: target))
            return
        }

        let persistedLayout = PersistedStoryGraphLayout(positionsByMode: pinnedStoryGraphPositionsByMode)
        guard let data = try? JSONEncoder().encode(persistedLayout) else { return }
        userDefaults.set(data, forKey: storyGraphLayoutStorageKey(for: target))
    }

    public func restoreCompactGraphLayoutForCurrentDatabase() {
        guard let target = databaseTarget else { return }
        restorePersistedGraphLayoutIfAvailable(for: target, graph: graph)
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
        guard let descriptor = tableDescriptors[tableName] else {
            presentedError = SQLiteUserError(kind: .notFound, message: "Table \(tableName) was not found.")
            return
        }

        openQuery(
            title: "\(tableName) Top 10",
            sqlText: """
            SELECT *
            FROM \(descriptor.qualifiedSQLIdentifier)
            LIMIT 10;
            """,
            runImmediately: true
        )
    }

    public func createTable(_ draft: TableCreateDraft) {
        guard databaseCapabilities.canCreateTable else {
            presentedError = SQLiteUserError(kind: .readOnly, message: "This database connection is read-only.")
            return
        }
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
        guard databaseCapabilities.canAlterSchema, let descriptor = activeTab?.descriptor else { return }
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
        guard databaseCapabilities.canAlterSchema, let descriptor = activeTab?.descriptor else { return }
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
        guard databaseCapabilities.canAlterSchema, let descriptor = activeTab?.descriptor else { return }
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
        guard databaseCapabilities.canDropColumns, let tab = activeTab else { return }
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

    public var exportProgress: RowExportProgress?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportCancellation: ExportCancellation?

    public func cancelExport() {
        exportCancellation?.cancel()
        exportTask?.cancel()
    }

    public func dismissExportProgress() {
        guard exportTask == nil else { return }
        exportProgress = nil
    }

    public var queryExportScopeLabel: String {
        guard let result = queryWorkspace.activeQuery?.result else { return "Executed result" }
        return Self.queryExportLabel(result)
    }

    private static func queryExportLabel(_ result: QueryResult) -> String {
        result.isTruncated
            ? "Executed result: \(result.rows.count) retained rows (truncated at \(result.rowLimit))"
            : "Executed result: \(result.rows.count) rows"
    }

    public func exportActiveTableRows(format: DataTransferFormat, scope: TableExportScope = .loadedRows) {
        guard !isRefreshing, let target = databaseTarget, let activeTab, exportTask == nil else { return }
        let generation = openGeneration
        let descriptor = activeTab.descriptor
        let rows = activeTab.chunk.rows.map(\.values)
        let query = activeTab.queryState
        let loaded = scope == .loadedRows
        let label = loaded ? "Loaded rows: \(rows.count) · \(activeTab.title)" : "All matching rows · \(activeTab.title) · total determined during export"
        let suffix = loaded ? "loaded-\(rows.count)" : "all-matching"
        guard let destination = presentExportPanel(defaultName: "\(activeTab.title)-\(suffix)", format: format,
            message: "\(label). Uses the captured filters and ordering. Switching databases cancels the export.") else { return }
        guard !isRefreshing, openGeneration == generation else { return }
        let source = databaseService
        beginExport(scope: label, totalRows: loaded ? rows.count : nil) { cancellation, progress in
            if loaded {
                return try await StreamingRowExport.write(names: descriptor.columns.map(\.name), rows: rows, to: destination, format: format, cancellation: cancellation, progress: progress)
            }
            return try await source.exportTableRows(query: query, descriptor: descriptor, to: destination, format: format, expectedTarget: target, cancellation: cancellation, progress: progress)
        }
    }

    public func exportActiveQueryResult(format: DataTransferFormat) {
        guard !isRefreshing, let activeQuery = queryWorkspace.activeQuery, !activeQuery.result.columns.isEmpty, exportTask == nil else { return }
        let generation = openGeneration
        let result = activeQuery.result
        let label = Self.queryExportLabel(result)
        let suffix = result.isTruncated ? "truncated-\(result.rows.count)" : "result-\(result.rows.count)"
        guard let destination = presentExportPanel(defaultName: "\(activeQuery.title)-\(suffix)", format: format,
            message: "\(label). Exports the displayed executed result. Editing SQL does not change this snapshot.") else { return }
        guard openGeneration == generation else { return }
        beginExport(scope: label, totalRows: result.rows.count) { cancellation, progress in
            try await StreamingRowExport.write(names: result.columns.map(\.name), rows: result.rows.map(\.values), to: destination, format: format, cancellation: cancellation, progress: progress)
        }
    }

    private func beginExport(scope: String, totalRows: Int?, operation: @escaping @Sendable (ExportCancellation, @escaping @Sendable (Int) -> Void) async throws -> Int) {
        let id = UUID()
        let cancellation = ExportCancellation()
        exportCancellation = cancellation
        exportProgress = RowExportProgress(id: id, scope: scope, totalRows: totalRows)
        exportTask = Task { [weak self] in
            do {
                let session = self
                let count = try await operation(cancellation) { count in
                    Task { @MainActor [weak session] in
                        guard session?.exportProgress?.id == id, session?.exportProgress?.isRunning == true else { return }
                        session?.exportProgress?.rowsWritten = max(session?.exportProgress?.rowsWritten ?? 0, count)
                    }
                }
                guard let self, self.exportProgress?.id == id else { return }
                self.exportProgress?.rowsWritten = count
                self.exportProgress?.outcome = "Exported \(count) rows"
            } catch {
                guard let self, self.exportProgress?.id == id else { return }
                if error is CancellationError || Task.isCancelled {
                    self.exportProgress?.outcome = "Cancelled · destination unchanged"
                } else {
                    self.exportProgress?.outcome = "Failed · destination unchanged"
                    self.presentedError = SQLiteUserError.from(error)
                }
            }
            guard let self, self.exportProgress?.id == id else { return }
            self.exportProgress?.isRunning = false
            self.exportTask = nil
            self.exportCancellation = nil
        }
    }

    public func importRowsIntoActiveTable(format: DataTransferFormat) {
        guard !isRefreshing, databaseCapabilities.canImportRows, let activeTab else { return }

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

    private func presentExportPanel(defaultName: String, format: DataTransferFormat, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.message = message
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
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

    func apply(snapshot: CatalogSnapshot, target: DatabaseTarget, documentURL: URL? = nil) {
        records.reset()
        records.catalog = snapshot
        records.relationships = RecordAccess.relationships(catalog: snapshot)
        let localURL = (documentURL ?? target.fileURL)?.standardizedFileURL
        let isSameDocument = databaseTarget == target && databaseURL == localURL
        if !isSameDocument { initializedGraphViewportDocument = nil }
        databaseTarget = target
        databaseURL = localURL
        databaseCapabilities = target.isPostgres ? .postgresReadOnly : .sqlite
        tableDescriptors = Dictionary(uniqueKeysWithValues: snapshot.descriptors.map { ($0.name, $0) })
        tables = snapshot.descriptors.map(\.summary)
        graph = snapshot.graph
        let sidecar: SchemaSidecar
        if let url = databaseURL {
            schemaMetadataState.reload(for: url, descriptors: snapshot.descriptors)
            sidecar = schemaMetadataState.sidecar
        } else {
            schemaMetadataState = SchemaMetadataState()
            sidecar = .empty
        }
        schemaSidecar = sidecar
        configureRecordMappings(schemaSidecar)
        updateGraphGrouping()
        graphLayout.reset(for: snapshot.graph)
        pinnedStoryGraphPositionsByMode = [:]
        restorePersistedGraphLayoutIfAvailable(for: target, graph: snapshot.graph)
        restorePersistedStoryGraphLayoutIfAvailable(for: target)
        activePaneSide = .right
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        showStoryCardsInGraph = false
        showOnlyStoryCardsInGraph = false
        queryWorkspace.loadSavedQueries(for: target)
        if !isSameDocument {
            selectedGraphNodeIDs = []
            openTabs = []
            isSkillsPresented = false
            isCreateTablePresented = false
            isAlterTablePresented = false
        }
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
        if let localURL { rememberRecentDatabase(localURL) }
    }

    private func updateGraphGrouping() {
        graphGrouping = GraphGrouping.resolve(graph: graph, descriptors: tableDescriptors, sidecar: schemaSidecar)
        graphLayout.setClusterHints(graphGrouping.nodeToGroup)
    }

    private func graphLayoutStorageKey(for url: URL) -> String {
        graphLayoutStorageKey(for: .sqlite(url))
    }

    private func storyGraphLayoutStorageKey(for url: URL) -> String {
        storyGraphLayoutStorageKey(for: .sqlite(url))
    }

    private func graphLayoutStorageKey(for target: DatabaseTarget) -> String {
        "SQLiteGraphStudio.graph-layout.v\(Self.graphLayoutStorageVersion).\(target.stableStorageKey)"
    }

    private func storyGraphLayoutStorageKey(for target: DatabaseTarget) -> String {
        "SQLiteGraphStudio.story-graph-layout.\(target.stableStorageKey)"
    }

    private func restorePersistedStoryGraphLayoutIfAvailable(for url: URL) {
        restorePersistedStoryGraphLayoutIfAvailable(for: .sqlite(url))
    }

    private func restorePersistedStoryGraphLayoutIfAvailable(for target: DatabaseTarget) {
        guard let data = userDefaults.data(forKey: storyGraphLayoutStorageKey(for: target)),
              let persistedLayout = try? JSONDecoder().decode(PersistedStoryGraphLayout.self, from: data)
        else {
            return
        }

        pinnedStoryGraphPositionsByMode = persistedLayout.cgPointsByMode
    }

    private func restorePersistedGraphLayoutIfAvailable(for url: URL, graph: SchemaGraph) {
        restorePersistedGraphLayoutIfAvailable(for: .sqlite(url), graph: graph)
    }

    private func restorePersistedGraphLayoutIfAvailable(for target: DatabaseTarget, graph: SchemaGraph) {
        guard let data = userDefaults.data(forKey: graphLayoutStorageKey(for: target)),
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

final class DatabaseDocumentOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let extensions: Set<String>
    init(extensions: Set<String>) { self.extensions = extensions }
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return extensions.contains(url.pathExtension.lowercased())
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
