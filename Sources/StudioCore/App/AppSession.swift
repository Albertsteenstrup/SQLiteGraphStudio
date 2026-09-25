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

/// One app-automation request to focus a table, optionally scoped to a declared relation.
public struct AutomationGraphFocusCommand: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let tableID: String
    public let sourceColumn: String?
    public let targetColumn: String?
    public let relationID: String?

    public init(
        id: UUID = UUID(),
        tableID: String,
        sourceColumn: String? = nil,
        targetColumn: String? = nil,
        relationID: String? = nil
    ) {
        self.id = id
        self.tableID = tableID
        self.sourceColumn = sourceColumn
        self.targetColumn = targetColumn
        self.relationID = relationID
    }
}

public struct GraphRevealRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let tableID: String

    public init(id: UUID = UUID(), tableID: String) {
        self.id = id
        self.tableID = tableID
    }
}

/// A one-shot viewport request from local automation. The graph view owns the
/// actual camera, so changing its saved session values alone cannot move it.
public struct AutomationGraphViewportCommand: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let fitVisibleTables: Bool
    public let transitionMilliseconds: Int

    public init(id: UUID = UUID(), fitVisibleTables: Bool, transitionMilliseconds: Int = 420) {
        self.id = id
        self.fitVisibleTables = fitVisibleTables
        self.transitionMilliseconds = transitionMilliseconds
    }
}

enum GridCellSliceDirection {
    case previous
    case next
}

struct GridCellSliceNavigationState: Equatable {
    let canReadPrevious: Bool
    let canReadNext: Bool
    let isLoading: Bool
}

private struct GridCellSliceContext: Equatable, Sendable {
    let tabID: UUID
    let row: Int
    let columnName: String
    let revision: Int
    let length: Int
    let recordID: String
}

@MainActor
@Observable
public final class AppSession {
    public var recentDatabaseURLs: [URL] = []
    public private(set) var databaseTarget: DatabaseTarget?
    /// The opened SQLite file or PostgreSQL connection document. Connection identity
    /// and database operations use `databaseTarget`, independently of this local URL.
    public var databaseURL: URL?
    public private(set) var schemaReview: SchemaReviewDocument?
    public private(set) var historicalExplanationArtifact: HistoricalExplanationArtifact?
    /// The currently displayed point while replaying a saved explanation. Its table
    /// and query panes are resolved only from the portable artifact snapshot.
    public private(set) var historicalReplayPointID: String?
    public var historicalReplayView: HistoricalExplanationArtifact.CapturedReplayView? {
        guard let historicalReplayPointID else { return nil }
        return historicalExplanationArtifact?.capturedView(forPointID: historicalReplayPointID)
    }
    /// Local container file used to restore an explicitly opened historical explanation tab.
    /// This path is session restoration metadata; it is never serialized into the artifact.
    public private(set) var historicalExplanationURL: URL?
    public private(set) var schemaReviewChanges: [String: SchemaTableChange] = [:]
    public private(set) var schemaReviewEdgeChanges: [String: SchemaChangeKind] = [:]
    /// Advances whenever the review's change sets are replaced, including a preview reload
    /// whose graph topology is unchanged but whose field changes are not.
    public private(set) var schemaReviewRevision = 0
    /// The latest request to bring a table into view, from outside the graph itself.
    public private(set) var graphRevealRequest: GraphRevealRequest?
    private var schemaComparisonTask: Task<Void, Never>?
    private var schemaComparisonID: UUID?
    public private(set) var schemaPreviewReloadError: String?
    private var schemaPreviewFileStamp: PreviewFileStamp?
    public private(set) var databaseCapabilities: DatabaseCapabilities = .none
    public var tables: [TableSummary] = [] {
        didSet { rebuildGraphNodeSizeProfile() }
    }
    public var graph: SchemaGraph = .empty {
        didSet { graphRevision &+= 1 }
    }
    private(set) var graphRevision = 0
    public private(set) var schemaMetadataState = SchemaMetadataState()
    public var metadataDiagnostics: [String] {
        migrationDiagnostics.map(\.displayText) + schemaMetadataState.diagnostics
    }

    public var schemaSidecar: SchemaSidecar = .empty {
        didSet { schemaSidecarRevision &+= 1 }
    }
    private(set) var schemaSidecarRevision = 0
    public private(set) var graphGrouping: GraphGrouping = .empty {
        didSet { graphGroupingRevision &+= 1 }
    }
    private(set) var graphGroupingRevision = 0
    public private(set) var automationGroupHints: [SchemaSidecar.ClusterHint]?
    public var leftPane = WorkspacePaneState(kind: .schema)
    public var rightPane = WorkspacePaneState(kind: .tables)
    public var activePaneSide: WorkspacePaneSide = .right
    public var maximizedPaneSide: WorkspacePaneSide?
    public var workspaceSplitFraction: CGFloat = 0.6
    public private(set) var workspaceCompactLayout = WorkspaceCompactLayout()
    public var selectedGraphNodeID: String?
    public var selectedGraphNodeIDs: Set<String> = []
    public var expandedGraphNodeIDs: Set<String> = []
    public var floatingDetailsCardTableID: String?
    public var floatingDetailsCardPosition: CGPoint?
    public var automationFocusCommand: AutomationGraphFocusCommand?
    /// A new table scope should leave any prior relation focus, even when its
    /// root table remains in the new subset.
    public private(set) var automationFocusResetRevision = 0
    public var automationViewportCommand: AutomationGraphViewportCommand?
    /// Invoked for user-originated graph changes so a presentation can pause progression.
    @ObservationIgnored public var onManualGraphInteraction: (@MainActor () -> Void)?
    public var graphNodeSizeMetric: GraphNodeSizeMetric = .uniform {
        didSet {
            rebuildGraphNodeSizeProfile()
        }
    }
    private(set) var graphNodeSizeProfile: GraphNodeSizeProfile = .uniform
    public var showAllGraphTableCards = false
    public var showClusterHalos = true
    /// Which graph decorations are switched on. Persisted, and edited from
    /// View ▸ Graph Visuals in the menu bar.
    public var graphVisuals: GraphVisualSettings = .default {
        didSet {
            guard graphVisuals != oldValue else { return }
            graphVisuals.save(to: userDefaults)
        }
    }
    public var openTabs: [TableTabModel] = []
    public var activeTabID: UUID?
    public var isRefreshing = false
    public var isTablePickerPresented = false
    public var isCreateTablePresented = false
    public var isAlterTablePresented = false
    public var isSkillsPresented = false
    public var refreshToast: RefreshToast?
    // Graph viewport state — shared so the minimap can be rendered outside the pane clip boundary
    public var graphZoom: CGFloat = 1.0
    public var graphPan: CGSize = .zero
    // Layout positions can be restored before this session has fitted a camera.
    var initializedGraphViewportDocument: String?
    public var presentedError: SQLiteUserError?

    public let records: RecordWorkspace
    private var gridCellSliceContext: GridCellSliceContext?
    @ObservationIgnored private var gridCellSliceRequestID = UUID()
    public private(set) var isLoadingGridCellSlice = false

    public let graphLayout = GraphLayoutModel()
    public var queryWorkspace: QueryWorkspaceModel

    /// Live progress while a chosen project folder is being searched.
    public private(set) var projectScan: ProjectScanState?
    /// Presented when a finished scan found more than one thing to open.
    public var projectCandidates: ProjectCandidateChoice?
    private var projectScanTask: Task<Void, Never>?
    /// The detached walk itself. `Task.detached` inherits neither cancellation
    /// nor priority, and awaiting its value is not interrupted by the waiter's
    /// own cancellation, so Cancel has to reach this handle directly.
    private var projectScanWork: Task<Result<ProjectScanResult, any Error>, Never>?

    /// The migration set behind an open migration model, and the version it was
    /// replayed through. Both are nil for every other kind of document.
    public private(set) var migrationSet: MigrationSet?
    public private(set) var selectedMigrationVersion: String?
    public private(set) var migrationReplaySummary: String?
    public private(set) var migrationDiagnostics: [MigrationDiagnostic] = []

    private var openGeneration = UUID()
    private var documentOpenTask: Task<Void, Error>?
    /// The in-flight migration replay, cancelled by the same paths that retire a
    /// dump open so the Cancel button stops the work rather than only the panel.
    private var migrationOpenTask: Task<MigrationSet, Error>?
    private var retiringDocumentOpens: [UUID: Task<Void, Never>] = [:]
    public private(set) var documentOpenProgress: String?
    private var pendingDatabaseClose: Task<Void, Never>?
    public private(set) var graphTableFilter = GraphTableFilter()
    /// Optional table scope requested by app automation. `nil` leaves the full graph visible.
    public var automationVisibleTableIDs: Set<String>? {
        didSet {
            guard oldValue != automationVisibleTableIDs else { return }
            automationViewRevision &+= 1
            automationRenderedViewRevision = nil
            automationRenderedTableIDs = []
            setGraphSelection(selectedGraphNodeIDs.intersection(graphVisibleTableIDs))
        }
    }
    /// Revision of the latest automation-driven graph presentation.
    public private(set) var automationViewRevision = 0
    /// Revision acknowledged by the rendered graph canvas, or `nil` until it paints.
    public private(set) var automationRenderedViewRevision: Int?
    /// Tables included in the last rendered acknowledgement.
    public private(set) var automationRenderedTableIDs: Set<String> = []
    public private(set) var graphRowCounts: [String: Int] = [:] {
        didSet { rebuildGraphNodeSizeProfile() }
    }
    public private(set) var graphRelationCounts: [String: Int] = [:] {
        didSet { rebuildGraphNodeSizeProfile() }
    }
    public var graphNodeSizeData: GraphNodeSizeData {
        GraphNodeSizeData(tables: tables, rowCounts: graphRowCounts, relationCounts: graphRelationCounts)
    }
    public private(set) var graphFilterProgress: Int?
    private var graphFilterGeneration = UUID()

    public var graphVisibleTableIDs: Set<String> {
        let nodeIDs = Set(graph.nodes.map(\.id))
        let filtered = Set(tables.filter {
            graphTableFilter.matches(fields: $0.columnCount, rows: graphRowCounts[$0.id] ?? $0.rowCount,
                                     relations: graphRelationCounts[$0.id, default: 0])
        }.map(\.id)).intersection(nodeIDs)
        guard let automationVisibleTableIDs else { return filtered }
        return filtered.intersection(automationVisibleTableIDs)
    }

    /// Applies an automation table scope; `nil` restores the full graph subject to the user's filter.
    public func setAutomationVisibleTableIDs(_ ids: Set<String>?) {
        automationVisibleTableIDs = ids
    }

    /// Advances the render acknowledgement after a camera, selection, expansion, or layout action.
    public func markAutomationViewChanged() {
        automationViewRevision &+= 1
        automationRenderedViewRevision = nil
        automationRenderedTableIDs = []
    }

    /// Restores the saved positions and exact pin set, including removal of temporary pins.
    public func restoreAutomationGraphLayout(_ snapshot: GraphLayoutSnapshot) {
        graphLayout.restore(
            snapshot, for: graph,
            presentation: showAllGraphTableCards ? .allCards : .compact,
            descriptorLookup: { [tableDescriptors] in tableDescriptors[$0] }
        )
        markAutomationViewChanged()
    }

    /// Requests native graph focus through the same table/relation layout used by the UI.
    public func setAutomationFocusCommand(_ command: AutomationGraphFocusCommand?) {
        automationFocusCommand = command
    }

    public func requestAutomationFocusReset() {
        automationFocusCommand = nil
        automationFocusResetRevision &+= 1
    }

    public func requestAutomationViewport(fitVisibleTables: Bool, transitionMilliseconds: Int = 420) {
        automationViewportCommand = AutomationGraphViewportCommand(
            fitVisibleTables: fitVisibleTables, transitionMilliseconds: transitionMilliseconds
        )
    }

    public func clearAutomationViewportCommand(id: UUID) {
        guard automationViewportCommand?.id == id else { return }
        automationViewportCommand = nil
    }

    /// Applies temporary, per-session graph groups without changing the authored sidecar.
    public func setAutomationGroups(_ hints: [SchemaSidecar.ClusterHint]?) {
        guard automationGroupHints != hints else { return }
        automationGroupHints = hints
        updateGraphGrouping()
        guard !graph.nodes.isEmpty else { return }
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let isShowingAllCards = showAllGraphTableCards
        let expandedIDs = expandedGraphNodeIDs
        graphLayout.stabilize(
            graph: graph,
            presentation: showAllGraphTableCards ? .allCards : .compact,
            descriptorLookup: { [tableDescriptors] in tableDescriptors[$0] },
            nodeSizeLookup: { [tableDescriptors, nodesByID] id in
                let title = nodesByID[id]?.title ?? id
                let style: GraphNodeCardStyle = isShowingAllCards || expandedIDs.contains(id) ? .expanded : .collapsed
                return GraphCardLayout.nodeSize(title: title, descriptor: tableDescriptors[id], style: style)
            },
            maxIterations: graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 0 : 140
        )
    }

    public func notifyManualGraphInteraction() {
        // A user gesture supersedes in-flight agent camera/focus instructions.
        // Their animation completions must not claim the user's new view.
        automationViewportCommand = nil
        automationFocusCommand = nil
        onManualGraphInteraction?()
    }

    /// Called after the canvas has drawn the requested graph revision.
    public func acknowledgeAutomationViewRendered(revision: Int, displayedTableIDs: Set<String>) {
        guard revision == automationViewRevision else { return }
        let visibleIDs = graphVisibleTableIDs
        let acknowledgedIDs = displayedTableIDs.intersection(visibleIDs)
        guard automationRenderedViewRevision != revision || automationRenderedTableIDs != acknowledgedIDs else { return }
        automationRenderedTableIDs = acknowledgedIDs
        automationRenderedViewRevision = revision
    }

    private func rebuildGraphNodeSizeProfile() {
        let profile = GraphNodeSizeProfile(metric: graphNodeSizeMetric, tables: tables,
                                          rowCounts: graphRowCounts, relationCounts: graphRelationCounts)
        if profile != graphNodeSizeProfile { graphNodeSizeProfile = profile }
    }

    public func cancelGraphFilter() {
        graphFilterGeneration = UUID()
        graphFilterProgress = nil
    }

    public func clearGraphFilter() {
        cancelGraphFilter()
        graphTableFilter = GraphTableFilter()
    }

    /// Restores a saved graph filter without querying the database. Row-bound
    /// filters use catalog estimates until the user asks for a fresh count.
    public func restoreGraphFilterWithoutCounting(_ filter: GraphTableFilter) {
        guard filter.isValid else { return }
        cancelGraphFilter()
        graphTableFilter = filter
        setGraphSelection(selectedGraphNodeIDs.intersection(graphVisibleTableIDs))
    }

    /// Row bounds use fresh counts, not PostgreSQL's missing or stale estimates.
    public func applyGraphFilter(_ filter: GraphTableFilter) async -> Bool {
        guard filter.isValid, hasOpenDatabase else { return false }
        guard schemaReview == nil || !filter.hasRowBounds else { return false }
        let generation = UUID()
        graphFilterGeneration = generation
        let databaseGeneration = openGeneration
        var counts: [String: Int] = [:]
        if filter.hasRowBounds {
            graphFilterProgress = 0
            defer { if graphFilterGeneration == generation { graphFilterProgress = nil } }
            do {
                for table in tables where filter.matchesFields(table.columnCount)
                    && filter.matchesRelations(graphRelationCounts[table.id, default: 0]) {
                    guard graphFilterGeneration == generation, openGeneration == databaseGeneration, !Task.isCancelled else { return false }
                    guard let descriptor = tableDescriptors[table.id] else { continue }
                    counts[table.id] = try await databaseService.countRows(query: TableQueryState(), descriptor: descriptor)
                    guard graphFilterGeneration == generation, openGeneration == databaseGeneration, !Task.isCancelled else { return false }
                    graphFilterProgress = counts.count
                }
            } catch {
                guard graphFilterGeneration == generation, openGeneration == databaseGeneration else { return false }
                presentedError = SQLiteUserError.from(error)
                return false
            }
        }
        graphRowCounts.merge(counts, uniquingKeysWith: { _, new in new })
        graphTableFilter = filter
        setGraphSelection(selectedGraphNodeIDs.intersection(graphVisibleTableIDs))
        return true
    }
    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var tableDescriptors: [String: EditableTableDescriptor] = [:]
    private static let graphNodeSizeMetricKey = "SQLiteGraphStudio.graph-node-size-metric"

    /// User choices are saved for the current database. Agent presentation choices
    /// can use the same method with persist=false and remain temporary.
    public func setGraphNodeSizeMetric(_ metric: GraphNodeSizeMetric, persist: Bool) {
        graphNodeSizeMetric = metric
        if persist, let target = databaseTarget {
            userDefaults.set(metric.rawValue, forKey: graphNodeSizeStorageKey(for: target))
        }
    }

    private func graphNodeSizeStorageKey(for target: DatabaseTarget) -> String {
        Self.graphNodeSizeMetricKey + "." + target.stableStorageKey
    }
    private static let postgresBookmarksKey = "SQLiteGraphStudio.postgres-file-bookmarks"
    private static let recentDatabaseStorageKey = "SQLiteGraphStudio.recent-databases"
    private static let graphLayoutStorageVersion = 2
    private static let allowedDatabaseExtensions = DatabaseDocument.supportedExtensions
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
        self.graphNodeSizeMetric = GraphNodeSizeMetric(rawValue: userDefaults.string(forKey: Self.graphNodeSizeMetricKey) ?? "") ?? .uniform
        self.graphVisuals = GraphVisualSettings.load(from: userDefaults)
        self.queryWorkspace = QueryWorkspaceModel(
            databaseService: databaseService,
            userDefaults: userDefaults
        )
        self.recentDatabaseURLs = Self.loadRecentDatabaseURLs(from: userDefaults)
        rebuildGraphNodeSizeProfile()
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
        guard loaded.omittedColumnIndices.isEmpty else {
            presentedError = SQLiteUserError(
                kind: .invalidInput,
                message: "This row contains large values omitted from the grid. Inspect those values in slices before treating the row as complete."
            )
            return
        }
        invalidateGridCellSlice()
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

    /// Opens the first bounded database-side slice for an omitted table-grid cell.
    /// The partial snapshot intentionally has no row identity or other field values.
    @discardableResult
    public func inspectCellSlice(in tab: TableTabModel, row: Int, columnName: String) -> Task<Void, Never> {
        guard openTabs.contains(where: { $0.id == tab.id }),
              let loaded = tab.row(at: row),
              let columnIndex = tab.descriptor.columns.firstIndex(where: { $0.name == columnName }),
              loaded.omittedColumnIndices.contains(columnIndex) else {
            return Task {}
        }
        let tabID = tab.id
        let revision = tab.revision
        let column = tab.descriptor.columns[columnIndex]
        let tableName = tab.title
        let previousRecordID = records.current?.id
        let previousInspectorPresentation = records.isPresented
        invalidateGridCellSlice()
        let requestID = UUID()
        gridCellSliceRequestID = requestID
        isLoadingGridCellSlice = true
        return Task { [weak self] in
            guard let self else { return }
            defer {
                if self.gridCellSliceRequestID == requestID { self.isLoadingGridCellSlice = false }
            }
            do {
                let read = try await tab.readOmittedCell(row: row, columnName: columnName)
                guard !Task.isCancelled,
                      self.gridCellSliceRequestID == requestID,
                      self.records.current?.id == previousRecordID,
                      self.records.isPresented == previousInspectorPresentation,
                      self.openTabs.contains(where: { $0.id == tabID }),
                      tab.revision == revision,
                      tab.isValueOmitted(row: row, column: columnIndex),
                      tab.canReadOmittedCell(row: row, columnName: columnName) else { return }
                guard let read else {
                    self.presentedError = DatabaseUserError(kind: .notFound, message: "The selected cell is no longer available.")
                    return
                }
                let snapshot = RecordSnapshot(
                    descriptor: tab.descriptor,
                    columns: [QueryResultColumn(name: columnName, typeLabel: column.typeLabel)],
                    values: [read.value],
                    identity: nil,
                    label: columnName,
                    partialCellRead: read
                )
                self.records.open(snapshot)
                self.records.originLabel = "\(tableName) · row \(row + 1) · \(columnName)"
                self.gridCellSliceContext = GridCellSliceContext(
                    tabID: tabID, row: row, columnName: columnName, revision: revision,
                    length: 4_096, recordID: snapshot.id
                )
            } catch {
                guard !Task.isCancelled,
                      self.gridCellSliceRequestID == requestID,
                      self.records.current?.id == previousRecordID,
                      self.records.isPresented == previousInspectorPresentation,
                      self.openTabs.contains(where: { $0.id == tabID }),
                      tab.revision == revision,
                      tab.canReadOmittedCell(row: row, columnName: columnName) else { return }
                self.presentedError = SQLiteUserError.from(error)
            }
        }
    }

    func gridCellSliceNavigation(for record: RecordSnapshot) -> GridCellSliceNavigationState? {
        guard validGridCellSliceContext(for: record) != nil,
              let read = record.partialCellRead else { return nil }
        return GridCellSliceNavigationState(
            canReadPrevious: read.offset > 0,
            canReadNext: read.hasMore,
            isLoading: isLoadingGridCellSlice
        )
    }

    /// Reads another bounded slice for a native grid cell without changing the
    /// inspector. The stable row identity is checked by the same database query
    /// that returns the slice, and the presentation context is revalidated after
    /// the await so a caller cannot apply stale search results to a new selection.
    public func readGridCellSlice(for record: RecordSnapshot, offset: Int, length: Int = 4_096) async throws -> BoundedCellRead {
        guard !isLoadingGridCellSlice,
              let context = validGridCellSliceContext(for: record),
              let tab = openTabs.first(where: { $0.id == context.tabID }) else {
            throw DatabaseUserError(kind: .invalidInput, message: "The selected cell view has changed. Reopen the large value before reading it.")
        }
        let requestID = gridCellSliceRequestID
        guard offset >= 0, offset < Int.max, (1...4_096).contains(length) else {
            throw DatabaseUserError(kind: .invalidInput, message: "Native cell slices require a nonnegative offset and a length from 1 to 4096.")
        }
        func ensureCurrentContext() throws {
            guard !Task.isCancelled,
                  gridCellSliceRequestID == requestID,
                  gridCellSliceContext == context,
                  records.current?.id == record.id,
                  records.isPresented,
                  openTabs.contains(where: { $0.id == context.tabID }),
                  tab.revision == context.revision,
                  tab.canReadOmittedCell(row: context.row, columnName: context.columnName) else {
                throw DatabaseUserError(kind: .invalidInput, message: "The selected cell view changed before the slice finished reading.")
            }
        }
        let read: BoundedCellRead?
        do {
            read = try await tab.readOmittedCell(
                row: context.row,
                columnName: context.columnName,
                offset: offset,
                length: length
            )
        } catch {
            try ensureCurrentContext()
            throw error
        }
        try ensureCurrentContext()
        guard let read else {
            throw DatabaseUserError(kind: .notFound, message: "The selected cell is no longer available.")
        }
        return read
    }

    /// Runs a full-value action through a database snapshot while checking the
    /// inspector selection before and after every database slice.
    public func withGridCellReadSnapshot<T: Sendable>(
        for record: RecordSnapshot,
        operation: @escaping @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> T
    ) async throws -> T {
        guard !isLoadingGridCellSlice,
              let context = validGridCellSliceContext(for: record),
              let tab = openTabs.first(where: { $0.id == context.tabID }) else {
            throw DatabaseUserError(kind: .invalidInput, message: "The selected cell view has changed. Reopen the large value before starting a full-value action.")
        }
        let requestID = gridCellSliceRequestID
        try ensureCurrentGridCellReadContext(for: record, context: context, requestID: requestID)
        return try await tab.withOmittedCellReadSnapshot(row: context.row, columnName: context.columnName) { snapshotReader in
            let guardedReader = BoundedCellSnapshotReader { offset, length in
                try self.ensureCurrentGridCellReadContext(for: record, context: context, requestID: requestID)
                guard let slice = try await snapshotReader.read(offset: offset, length: length) else {
                    throw DatabaseUserError(kind: .notFound, message: "The selected cell is no longer available in this snapshot.")
                }
                try self.ensureCurrentGridCellReadContext(for: record, context: context, requestID: requestID)
                return slice
            }
            let result = try await operation(guardedReader)
            try self.ensureCurrentGridCellReadContext(for: record, context: context, requestID: requestID)
            return result
        }
    }

    @discardableResult
    func navigateGridCellSlice(for record: RecordSnapshot, direction: GridCellSliceDirection) -> Task<Void, Never> {
        guard !isLoadingGridCellSlice,
              let context = validGridCellSliceContext(for: record),
              let currentRead = record.partialCellRead else { return Task {} }
        let offset: Int
        switch direction {
        case .previous:
            guard currentRead.offset > 0 else { return Task {} }
            offset = max(0, currentRead.offset - context.length)
        case .next:
            guard currentRead.hasMore else { return Task {} }
            let (nextOffset, overflow) = currentRead.offset.addingReportingOverflow(currentRead.returnedLength)
            guard !overflow, nextOffset < Int.max else { return Task {} }
            offset = nextOffset
        }
        return showGridCellSlice(for: record, offset: offset)
    }

    @discardableResult
    func showGridCellSlice(for record: RecordSnapshot, offset: Int) -> Task<Void, Never> {
        guard !isLoadingGridCellSlice,
              offset >= 0, offset < Int.max,
              let context = validGridCellSliceContext(for: record) else { return Task {} }
        guard let tab = openTabs.first(where: { $0.id == context.tabID }) else { return Task {} }
        let column = tab.descriptor.columns.first { $0.name == context.columnName }
        guard let column else { return Task {} }

        let requestID = UUID()
        gridCellSliceRequestID = requestID
        isLoadingGridCellSlice = true
        return Task { [weak self] in
            guard let self else { return }
            defer {
                if self.gridCellSliceRequestID == requestID { self.isLoadingGridCellSlice = false }
            }
            do {
                let read = try await tab.readOmittedCell(
                    row: context.row,
                    columnName: context.columnName,
                    offset: offset,
                    length: context.length
                )
                guard !Task.isCancelled,
                      self.gridCellSliceRequestID == requestID,
                      self.gridCellSliceContext == context,
                      self.records.current?.id == record.id,
                      self.records.isPresented,
                      self.openTabs.contains(where: { $0.id == context.tabID }),
                      tab.revision == context.revision,
                      tab.canReadOmittedCell(row: context.row, columnName: context.columnName) else { return }
                guard let read else {
                    self.gridCellSliceContext = nil
                    self.presentedError = DatabaseUserError(kind: .notFound, message: "The selected cell is no longer available.")
                    return
                }
                let snapshot = RecordSnapshot(
                    descriptor: tab.descriptor,
                    columns: [QueryResultColumn(name: context.columnName, typeLabel: column.typeLabel)],
                    values: [read.value],
                    identity: nil,
                    label: context.columnName,
                    partialCellRead: read
                )
                self.records.open(snapshot)
                self.records.originLabel = "\(tab.title) · row \(context.row + 1) · \(context.columnName)"
                self.gridCellSliceContext = GridCellSliceContext(
                    tabID: context.tabID, row: context.row, columnName: context.columnName,
                    revision: context.revision, length: context.length, recordID: snapshot.id
                )
            } catch {
                guard !Task.isCancelled,
                      self.gridCellSliceRequestID == requestID,
                      self.gridCellSliceContext == context,
                      self.records.current?.id == record.id,
                      self.records.isPresented,
                      tab.revision == context.revision,
                      tab.canReadOmittedCell(row: context.row, columnName: context.columnName) else { return }
                self.presentedError = SQLiteUserError.from(error)
            }
        }
    }

    /// Displays a slice already read during a consistent full-cell operation,
    /// such as Find. Reusing that result avoids a new database read after the
    /// snapshot closes.
    func showGridCellSlice(for record: RecordSnapshot, read: BoundedCellRead) {
        guard !isLoadingGridCellSlice,
              let context = validGridCellSliceContext(for: record),
              let tab = openTabs.first(where: { $0.id == context.tabID }),
              let column = tab.descriptor.columns.first(where: { $0.name == context.columnName }) else { return }
        let snapshot = RecordSnapshot(
            descriptor: tab.descriptor,
            columns: [QueryResultColumn(name: context.columnName, typeLabel: column.typeLabel)],
            values: [read.value],
            identity: nil,
            label: context.columnName,
            partialCellRead: read
        )
        gridCellSliceRequestID = UUID()
        records.open(snapshot)
        records.originLabel = "\(tab.title) · row \(context.row + 1) · \(context.columnName)"
        gridCellSliceContext = GridCellSliceContext(
            tabID: context.tabID, row: context.row, columnName: context.columnName,
            revision: context.revision, length: context.length, recordID: snapshot.id
        )
    }

    private func validGridCellSliceContext(for record: RecordSnapshot) -> GridCellSliceContext? {
        guard let context = gridCellSliceContext,
              let tab = openTabs.first(where: { $0.id == context.tabID }),
              records.isPresented,
              records.current?.id == record.id,
              context.recordID == record.id,
              record.partialCellRead != nil,
              record.values.count == 1,
              record.columns.map(\.name) == [context.columnName],
              record.descriptor == tab.descriptor,
              tab.revision == context.revision,
              tab.canReadOmittedCell(row: context.row, columnName: context.columnName) else { return nil }
        return context
    }

    private func ensureCurrentGridCellReadContext(
        for record: RecordSnapshot,
        context: GridCellSliceContext,
        requestID: UUID
    ) throws {
        guard !Task.isCancelled,
              gridCellSliceRequestID == requestID,
              gridCellSliceContext == context,
              validGridCellSliceContext(for: record) == context else {
            throw DatabaseUserError(kind: .invalidInput, message: "The selected cell view changed before the full-value action finished.")
        }
    }

    private func invalidateGridCellSlice() {
        gridCellSliceContext = nil
        gridCellSliceRequestID = UUID()
        isLoadingGridCellSlice = false
    }

    public func inspectQueryRecord(result: QueryResult, row: QueryResultRow, executedSQL: String? = nil) {
        do {
            let descriptor = RecordQueryOrigin.descriptor(executedSQL: executedSQL, result: result, catalog: records.catalog)
            invalidateGridCellSlice()
            records.open(try RecordAccess.snapshot(descriptor: descriptor, columns: result.columns, values: row.values))
            records.originLabel = "Query result · row \(row.id + 1)"
        } catch { presentedError = SQLiteUserError.from(error) }
    }

    public var activeTab: TableTabModel? {
        openTabs.first(where: { $0.id == activeTabID }) ?? openTabs.first
    }

    public var hasOpenDatabase: Bool {
        databaseTarget != nil || schemaReview != nil
    }

    /// Whether the workspace should offer the SQL pane at all. A schema review
    /// has no database target and keeps the pane set it has always had; a
    /// document that is open but cannot run queries — a migration model — hides
    /// it rather than offering a pane that can only fail.
    public var canShowQueryPane: Bool {
        databaseTarget == nil || databaseCapabilities.canRunQueries
    }

    public var databaseDisplayName: String {
        schemaReview?.title ?? databaseTarget?.displayName ?? "No Database"
    }

    public var isPostgreSQL: Bool {
        databaseTarget?.isPostgres ?? false
    }

    public func presentOpenDatabasePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Custom archive/document suffixes do not reliably map to system UTIs.
        panel.allowedContentTypes = []
        let documentFilter = DatabaseDocumentOpenPanelDelegate(extensions: DatabaseDocument.supportedExtensions)
        panel.delegate = documentFilter
        panel.title = "Open Database File"
        panel.message = DatabaseDocument.supportedFormatsDescription
        panel.prompt = "Open"

        let presentingWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        panel.begin { [self, documentFilter, weak presentingWindow] response in
            withExtendedLifetime(documentFilter) {
                presentingWindow?.makeKeyAndOrderFront(nil)
                guard response == .OK, let url = panel.url else { return }
                Task { await openDocument(url: url) }
            }
        }
    }

    public func openDatabase(url: URL) async {
        await openDatabase(url: url, changeBaseline: nil)
    }

    private func openDatabase(url: URL, changeBaseline: SchemaRefreshSnapshot?) async {
        clearGraphFilter()
        graphRowCounts = [:]
        graphRelationCounts = [:]
        retireDocumentOpen()
        documentOpenProgress = nil
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
            apply(snapshot: snapshot, target: .sqlite(url.standardizedFileURL))
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

    public func openDocument(url: URL) async {
        let fileExtension = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if fileExtension == "sgexplanation" {
            do {
                let artifact = try HistoricalExplanationStore.load(url)
                openHistoricalExplanation(artifact, from: url)
            } catch {
                presentedError = SQLiteUserError.from(error)
            }
        } else if exists, isDirectory.boolValue {
            // A folder of versioned SQL files is a migration model; any other
            // folder is a project to search, which is what dropping one on the app
            // or passing it as an argument is asking for.
            let resolved = try? await BackgroundWork.run { try ProjectScanner.migrationSet(at: url) }
            if let resolved {
                await openMigrations(at: url, version: nil, changeBaseline: nil, resolved: resolved)
            } else {
                scanProject(at: url)
            }
        } else if fileExtension == "sql" {
            await openMigrations(at: url, version: nil, changeBaseline: nil)
        } else if ["sgreview", "sgpreview"].contains(fileExtension) {
            await openSchemaReview(url: url)
        } else if DatabaseDocument.isArchive(url) {
            await openPostgreSQLDump(url: url)
        } else if PostgresConnectionDocument.supportedFileExtensions.contains(fileExtension) {
            await openPostgreSQLDocument(url: url)
        } else if DatabaseDocument.sqliteExtensions.contains(fileExtension) {
            await openDatabase(url: url)
        } else {
            presentedError = DatabaseUserError(kind: .invalidInput, message: "This database file type is not supported.")
        }
    }

    private func openPostgreSQLDump(url: URL) async {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        clearGraphFilter()
        graphRowCounts = [:]
        graphRelationCounts = [:]
        retireDocumentOpen()
        let generation = UUID()
        openGeneration = generation
        queryWorkspace.stopAll()
        cancelExport()
        isRefreshing = true
        presentedError = nil
        documentOpenProgress = "Opening PostgreSQL backup…"
        let opening = Task {
            await pendingDatabaseClose?.value
            try Task.checkCancellation()
            try await databaseService.open(dump: url) { [weak self] message in
                await self?.updateDocumentOpenProgress(message, generation: generation)
            }
        }
        documentOpenTask = opening
        defer {
            if openGeneration == generation {
                isRefreshing = false
                documentOpenProgress = nil
                documentOpenTask = nil
            }
        }
        do {
            try await opening.value
            guard openGeneration == generation else { return }
            documentOpenProgress = "Loading schema graph…"
            let snapshot = try await databaseService.loadCatalogSnapshot()
            guard openGeneration == generation else { return }
            apply(snapshot: snapshot, target: .postgresDump(url.standardizedFileURL))
            rememberPostgreSQLFileAccess(url)
        } catch {
            guard openGeneration == generation else { return }
            await databaseService.close()
            guard openGeneration == generation else { return }
            closeDatabase()
            if !(error is CancellationError) { presentedError = SQLiteUserError.from(error) }
        }
    }

    private func updateDocumentOpenProgress(_ message: String, generation: UUID) {
        if openGeneration == generation { documentOpenProgress = message }
    }

    public func cancelDocumentOpen() { closeDatabase() }

    public func closeAndWait() async {
        closeDatabase()
        for cleanup in retiringDocumentOpens.values { await cleanup.value }
        await pendingDatabaseClose?.value
    }

    private func retireDocumentOpen() {
        if let replay = migrationOpenTask {
            migrationOpenTask = nil
            replay.cancel()
        }
        guard let opening = documentOpenTask else { return }
        documentOpenTask = nil
        opening.cancel()
        let id = UUID()
        retiringDocumentOpens[id] = Task { [weak self] in
            _ = try? await opening.value
            self?.retiringDocumentOpens.removeValue(forKey: id)
        }
    }

    public func openPostgreSQLDocument(url: URL) async {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        clearGraphFilter()
        graphRowCounts = [:]
        graphRelationCounts = [:]
        retireDocumentOpen()
        documentOpenProgress = nil
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
            rememberPostgreSQLFileAccess(url)
            databaseCapabilities = .postgresReadOnly
            StudioLog.ui.info(
                "Loaded PostgreSQL document \(url.lastPathComponent, privacy: .public) for \(document.configuration.host, privacy: .public):\(document.configuration.port, privacy: .public)/\(document.configuration.database, privacy: .public)"
            )
        } catch {
            guard openGeneration == generation else { return }
            presentedError = SQLiteUserError.from(error)
        }
    }

    private func rememberPostgreSQLFileAccess(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var bookmarks = userDefaults.dictionary(forKey: Self.postgresBookmarksKey) ?? [:]
        bookmarks[url.standardizedFileURL.path] = bookmark
        let recentPaths = Set(recentDatabaseURLs.map(\.path))
        userDefaults.set(bookmarks.filter { recentPaths.contains($0.key) }, forKey: Self.postgresBookmarksKey)
    }

    public func openRecentDatabase(_ url: URL) {
        guard recentDatabaseURLs.contains(url.standardizedFileURL) else { return }
        var resolvedURL = url
        if let data = userDefaults.dictionary(forKey: Self.postgresBookmarksKey)?[url.standardizedFileURL.path] as? Data {
            var stale = false
            resolvedURL = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
        }
        Task { await openDocument(url: resolvedURL) }
    }

    // MARK: - Project folders

    public func presentOpenProjectFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Project Folder"
        panel.message = "Graph Studio searches this folder and its subfolders for databases, PostgreSQL backups, connection documents and migration folders.\nDependency and build folders, and anything the project's .gitignore excludes, are skipped."
        panel.prompt = "Search"

        let presentingWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        panel.begin { [self, weak presentingWindow] response in
            presentingWindow?.makeKeyAndOrderFront(nil)
            guard response == .OK, let url = panel.url else { return }
            scanProject(at: url)
        }
    }

    public func scanProject(at url: URL) {
        cancelProjectScan()
        projectCandidates = nil
        presentedError = nil
        let root = url.standardizedFileURL
        projectScan = ProjectScanState(root: root)

        let reporter = ProjectScanReporter { [weak self] progress in
            Task { @MainActor in self?.updateProjectScan(progress, root: root) }
        }
        let work = Task.detached(priority: .userInitiated) { () -> Result<ProjectScanResult, any Error> in
            do {
                return .success(try ProjectScanner.scan(root: root) { reporter.report($0) })
            } catch {
                return .failure(error)
            }
        }
        projectScanWork = work
        projectScanTask = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.finishProjectScan(outcome, root: root)
        }
    }

    public func cancelProjectScan() {
        projectScanWork?.cancel()
        projectScanWork = nil
        projectScanTask?.cancel()
        projectScanTask = nil
        projectScan = nil
    }

    public func dismissProjectCandidates() {
        projectCandidates = nil
    }

    public func openCandidate(_ candidate: ProjectCandidate, migrationVersion: String? = nil) {
        projectCandidates = nil
        switch candidate.kind {
        case .migrationSet, .schemaScript:
            // The search already resolved this set; opening it again would only
            // re-read the same directory.
            Task {
                await openMigrations(at: candidate.url, version: migrationVersion,
                                     changeBaseline: nil, resolved: candidate.migrationSet)
            }
        case .sqliteDatabase, .postgresBackup, .postgresConnection:
            Task { await openDocument(url: candidate.url) }
        }
    }

    private func updateProjectScan(_ progress: ProjectScanProgress, root: URL) {
        guard var state = projectScan, state.root == root else { return }
        state.progress = progress
        projectScan = state
    }

    private func finishProjectScan(_ outcome: Result<ProjectScanResult, any Error>, root: URL) {
        guard projectScan?.root == root else { return }
        projectScan = nil
        projectScanTask = nil
        projectScanWork = nil

        switch outcome {
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            presentedError = SQLiteUserError.from(error)
        case .success(let result):
            guard let first = result.candidates.first else {
                presentedError = DatabaseUserError(
                    kind: .notFound,
                    message: "Nothing Graph Studio can open was found in ‘\(root.lastPathComponent)’.",
                    recoverySuggestion: "Searched \(result.directoriesVisited) folders and \(result.filesInspected) files. It looks for SQLite databases, PostgreSQL backups and connection documents, and folders of versioned .sql migrations."
                )
                return
            }
            guard result.candidates.count > 1 else {
                openCandidate(first)
                return
            }
            projectCandidates = ProjectCandidateChoice(
                root: root,
                candidates: result.candidates,
                summary: Self.scanSummary(result)
            )
        }
    }

    private static func scanSummary(_ result: ProjectScanResult) -> String {
        var parts = [
            "\(result.candidates.count) matches",
            "\(result.directoriesVisited) folders searched",
        ]
        if result.skippedDirectoryCount > 0 { parts.append("\(result.skippedDirectoryCount) skipped") }
        if result.reachedLimit { parts.append("search limit reached") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Migration models

    /// Replays `url` — a folder of versioned SQL files, or a single schema
    /// script — and opens the schema it describes.
    public func openMigrations(at url: URL, version: String?) async {
        await openMigrations(at: url, version: version, changeBaseline: nil)
    }

    /// Re-replays the open migration set through another version. Graph layout,
    /// saved queries and notes stay with the set, so versions can be compared.
    public func selectMigrationVersion(_ version: String?) {
        guard case .migrations(let url)? = databaseTarget, version != selectedMigrationVersion else { return }
        let baseline = SchemaRefreshSnapshot(descriptors: tableDescriptors, graph: graph, sidecar: schemaSidecar)
        persistCurrentGraphLayout()
        Task { await openMigrations(at: url, version: version, changeBaseline: baseline) }
    }

    private func openMigrations(at url: URL, version: String?, changeBaseline: SchemaRefreshSnapshot?,
                                resolved: MigrationSet? = nil) async {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        clearGraphFilter()
        graphRowCounts = [:]
        graphRelationCounts = [:]
        retireDocumentOpen()
        records.reset()
        let generation = UUID()
        openGeneration = generation
        queryWorkspace.stopAll()
        cancelExport()

        isRefreshing = true
        presentedError = nil
        documentOpenProgress = "Reading migrations…"
        defer {
            if openGeneration == generation {
                isRefreshing = false
                documentOpenProgress = nil
                migrationOpenTask = nil
            }
        }

        let service = databaseService
        let opening = Task { [weak self] () -> MigrationSet in
            await self?.pendingDatabaseClose?.value
            try Task.checkCancellation()
            // Resolving the folder reads it from disk; keep that off the main
            // actor along with the replay it feeds.
            let set: MigrationSet
            if let resolved {
                set = resolved
            } else {
                set = try await BackgroundWork.run { try ProjectScanner.migrationSet(at: url) }
            }
            let through = version.flatMap { set.index(ofVersion: $0) == nil ? nil : $0 } ?? set.latest?.version
            try await service.open(migrations: set, through: through, sourceURL: url) { [weak self] message in
                await self?.updateDocumentOpenProgress(message, generation: generation)
            }
            return set
        }
        migrationOpenTask = opening

        do {
            let set = try await opening.value
            let resolved = version.flatMap { set.index(ofVersion: $0) == nil ? nil : $0 } ?? set.latest?.version
            guard openGeneration == generation else { return }
            documentOpenProgress = "Building the schema graph…"
            let snapshot = try await databaseService.loadCatalogSnapshot()
            let model = await databaseService.migrationModel
            guard openGeneration == generation else { return }

            migrationSet = set
            selectedMigrationVersion = resolved
            migrationDiagnostics = model?.diagnostics ?? []
            migrationReplaySummary = Self.replaySummary(set: set, version: resolved, model: model,
                                                        descriptors: snapshot.descriptors)
            apply(snapshot: snapshot, target: .migrations(url.standardizedFileURL))
            if let changeBaseline {
                refreshToast = Self.refreshSummary(
                    before: changeBaseline,
                    after: SchemaRefreshSnapshot(descriptors: tableDescriptors, graph: graph, sidecar: schemaSidecar)
                ).map { RefreshToast(message: $0) }
            }
            StudioLog.ui.info("Replayed \(set.files.count, privacy: .public) migration files from \(url.lastPathComponent, privacy: .public)")
        } catch {
            guard openGeneration == generation else { return }
            await databaseService.close()
            guard openGeneration == generation else { return }
            migrationSet = nil
            selectedMigrationVersion = nil
            migrationReplaySummary = nil
            migrationDiagnostics = []
            if !(error is CancellationError) { presentedError = SQLiteUserError.from(error) }
        }
    }

    private static func replaySummary(set: MigrationSet, version: String?,
                                      model: MigrationSchemaModel?, descriptors: [TableDescriptor]) -> String {
        let applied = set.files(through: version).count
        let views = descriptors.count { $0.objectType == .view || $0.objectType == .materializedView }
        let tables = descriptors.count - views
        var parts = ["\(applied) of \(set.files.count) migrations", "\(tables) table\(tables == 1 ? "" : "s")"]
        if views > 0 { parts.append("\(views) view\(views == 1 ? "" : "s")") }
        if let model { parts.append("\(model.statementCount) statements") }
        parts.append(set.dialect.displayName)
        return parts.joined(separator: " · ")
    }

    static func capabilities(for target: DatabaseTarget) -> DatabaseCapabilities {
        switch target {
        case .sqlite:
            return .sqlite
        case .postgres, .postgresDump:
            return .postgresReadOnly
        case .migrations:
            return .migrationsSchemaOnly
        }
    }

    public func closeDatabase() {
        schemaComparisonTask?.cancel()
        schemaComparisonTask = nil
        schemaComparisonID = nil
        schemaPreviewReloadError = nil
        schemaPreviewFileStamp = nil
        schemaReview = nil
        historicalExplanationArtifact = nil
        historicalReplayPointID = nil
        historicalExplanationURL = nil
        schemaReviewChanges = [:]
        schemaReviewEdgeChanges = [:]
        schemaReviewRevision &+= 1
        graphRevealRequest = nil
        clearGraphFilter()
        graphRowCounts = [:]
        graphRelationCounts = [:]
        retireDocumentOpen()
        documentOpenProgress = nil
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
        automationGroupHints = nil
        automationFocusCommand = nil
        automationViewportCommand = nil
        automationVisibleTableIDs = nil
        schemaMetadataState = SchemaMetadataState()
        leftPane = WorkspacePaneState(kind: .schema)
        rightPane = WorkspacePaneState(kind: .tables)
        activePaneSide = .right
        preferSchemaPaneWhenCompact()
        maximizedPaneSide = nil
        selectedGraphNodeID = nil
        selectedGraphNodeIDs = []
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        openTabs = []
        migrationSet = nil
        selectedMigrationVersion = nil
        migrationReplaySummary = nil
        migrationDiagnostics = []

        activeTabID = nil
        tableDescriptors = [:]
        graphLayout.setClusterHints([:])
        graphLayout.reset(for: .empty)
        queryWorkspace.reset()
        refreshToast = nil
        markAutomationViewChanged()
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

    public func clusterLabel(for tableName: String) -> String? {
        graphGrouping.group(for: tableName)?.label
    }

    public func clusterColorHex(for tableName: String) -> String? {
        graphGrouping.group(for: tableName)?.colorHex
    }

    /// Returns the task that reloads the schema, or nil when the refresh
    /// finishes synchronously or there is nothing open to refresh.
    @discardableResult
    public func refreshSchema() -> Task<Void, Never>? {
        if schemaReview?.proposal != nil { refreshSchemaPreviewIfChanged(force: true); return nil }
        if schemaReview != nil, let databaseURL { return Task { await openSchemaReview(url: databaseURL) } }
        guard let target = databaseTarget else { return nil }
        let baseline = SchemaRefreshSnapshot(
            descriptors: tableDescriptors,
            graph: graph,
            sidecar: schemaSidecar
        )
        persistCurrentGraphLayout()
        switch target {
        case .sqlite(let databaseURL):
            return Task { await openDatabase(url: databaseURL, changeBaseline: baseline) }
        case .migrations(let url):
            return Task { await openMigrations(at: url, version: selectedMigrationVersion, changeBaseline: baseline) }
        case .postgres, .postgresDump:
            let generation = openGeneration
            let documentURL = databaseURL
            return Task {
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
        if schemaReview != nil { selectGraphNode(tableName); return nil }
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
        if autoLoad, databaseCapabilities.canBrowseRows {
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

    /// Selects a table and asks the graph to bring it into view — for choices made
    /// outside the canvas, such as a schema review's table list.
    public func revealGraphNode(_ nodeID: String) {
        guard graph.contains(nodeID: nodeID) else { return }
        selectGraphNode(nodeID)
        graphRevealRequest = GraphRevealRequest(tableID: nodeID)
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

    /// Temporarily brings a chosen set of tables together without changing the
    /// authored domain layout. The displayed card sizes determine their spacing.
    public func compactGraphTables(_ tableIDs: [String], columns: Int = 3, around center: CGPoint = .zero) {
        let items = tableIDs.compactMap { id -> GraphCompactPlacement.Item? in
            guard let node = graph.node(id: id) else { return nil }
            let style: GraphNodeCardStyle = isGraphNodeExpanded(id) ? .expanded : .collapsed
            let size = GraphCardLayout.nodeSize(title: node.title, descriptor: tableDescriptors[id], style: style)
            return GraphCompactPlacement.Item(id: id, size: size)
        }
        for (id, position) in GraphCompactPlacement.positions(for: items, columns: columns, around: center) {
            graphLayout.pin(nodeID: id, at: position)
        }
    }

    public func persistCurrentGraphLayout() {
        guard let target = databaseTarget, !graph.nodes.isEmpty else { return }
        let snapshot = graphLayout.snapshot(for: graph)
        let persistedLayout = PersistedGraphLayout(snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(persistedLayout) else { return }
        userDefaults.set(data, forKey: graphLayoutStorageKey(for: target))
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
        guard schemaReview == nil else { return }
        guard let descriptor = tableDescriptors[tableName] else {
            presentedError = SQLiteUserError(kind: .notFound, message: "Table \(tableName) was not found.")
            return
        }

        openQuery(
            title: "\(tableName) Top 10",
            sqlText: """
            SELECT *
            FROM \(descriptor.tableDataSQLSource)
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
        let loaded = scope == .loadedRows
        if loaded, activeTab.chunk.rows.contains(where: { !$0.omittedColumnIndices.isEmpty }) {
            presentedError = SQLiteUserError(
                kind: .invalidInput,
                message: "Loaded rows contain large values omitted from the grid. Choose All matching rows to export the full values."
            )
            return
        }
        let generation = openGeneration
        let descriptor = activeTab.descriptor
        let rows = activeTab.chunk.rows.map(\.values)
        let query = activeTab.queryState
        let label = loaded ? "Loaded rows: \(rows.count) · \(activeTab.title)" : "All matching rows · \(activeTab.title) · total determined during export"
        let suffix = loaded ? "loaded-\(rows.count)" : "all-matching"
        presentExportPanel(defaultName: "\(activeTab.title)-\(suffix)", format: format,
            message: "\(label). Uses the captured filters and ordering. Switching databases cancels the export.") { [self] destination in
            guard let destination, !isRefreshing, openGeneration == generation, exportTask == nil else { return }
            let source = databaseService
            beginExport(scope: label, totalRows: loaded ? rows.count : nil) { cancellation, progress in
                if loaded {
                    return try await StreamingRowExport.write(names: descriptor.columns.map(\.name), rows: rows, to: destination, format: format, cancellation: cancellation, progress: progress)
                }
                return try await source.exportTableRows(query: query, descriptor: descriptor, to: destination, format: format, expectedTarget: target, cancellation: cancellation, progress: progress)
            }
        }
    }

    public func exportActiveQueryResult(format: DataTransferFormat) {
        guard !isRefreshing, let activeQuery = queryWorkspace.activeQuery, !activeQuery.result.columns.isEmpty, exportTask == nil else { return }
        let generation = openGeneration
        let result = activeQuery.result
        let label = Self.queryExportLabel(result)
        let suffix = result.isTruncated ? "truncated-\(result.rows.count)" : "result-\(result.rows.count)"
        presentExportPanel(defaultName: "\(activeQuery.title)-\(suffix)", format: format,
            message: "\(label). Exports the displayed executed result. Editing SQL does not change this snapshot.") { [self] destination in
            guard let destination, !isRefreshing, openGeneration == generation, exportTask == nil else { return }
            beginExport(scope: label, totalRows: result.rows.count) { cancellation, progress in
                try await StreamingRowExport.write(names: result.columns.map(\.name), rows: result.rows.map(\.values), to: destination, format: format, cancellation: cancellation, progress: progress)
            }
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
        guard !isRefreshing, databaseCapabilities.canImportRows, let target = databaseTarget, let activeTab else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.prompt = "Import"
        let generation = openGeneration
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url, openGeneration == generation, databaseCapabilities.canImportRows else { return }
            Task {
                guard openGeneration == generation else { return }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let result = try await databaseService.importRows(into: activeTab.descriptor, text: text, format: format, expectedTarget: target)
                    guard openGeneration == generation else { return }
                    activeTab.inlineErrorMessage = result.messages.first
                    await activeTab.reload()
                } catch {
                    guard openGeneration == generation else { return }
                    presentedError = SQLiteUserError.from(error)
                }
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

    /// A visual automation action must expose its target even when another
    /// pane was maximized or the workspace is too narrow for two panes.
    public func revealPaneForAutomation(_ kind: PaneContentKind, preferredSide: WorkspacePaneSide = .right) {
        ensurePaneVisible(kind, preferredSide: preferredSide)
        guard let targetSide = side(containing: kind) else { return }
        if kind != .schema && showAllGraphTableCards {
            showAllGraphTableCards = false
        }
        if let maximizedPaneSide, maximizedPaneSide != targetSide {
            self.maximizedPaneSide = nil
        }
        activePaneSide = targetSide
    }

    public func revealSchemaForAutomation() {
        revealPaneForAutomation(.schema, preferredSide: .left)
    }

    public var isSchemaPaneVisiblyDisplayed: Bool {
        guard let schemaSide = side(containing: .schema) else { return false }
        if let maximizedPaneSide { return maximizedPaneSide == schemaSide }
        if showAllGraphTableCards { return true }
        return !isWorkspaceCompact || activePaneSide == schemaSide
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

    public var isWorkspaceCompact: Bool {
        workspaceCompactLayout.isCompact
    }

    /// The one pane a narrow workspace has room for, or `nil` while both fit.
    /// The user keeps steering it: the active side follows table and query
    /// openings, and dock taps swap content into whichever side is on screen.
    public var compactVisibleSide: WorkspacePaneSide? {
        workspaceCompactLayout.isCompact ? activePaneSide : nil
    }

    /// Reports the workspace width as the window is resized, tiled into Split
    /// View, or moved between Stage Manager slots. When the layout first runs
    /// out of room for two panes, the graph is the one that stays.
    public func updateWorkspaceWidth(_ width: CGFloat) {
        guard workspaceCompactLayout.update(width: width) else { return }
        preferSchemaPaneWhenCompact()
    }

    /// Focuses the pane holding the schema graph whenever only one pane fits.
    ///
    /// A compact workspace shows the active side and nothing else, so anything
    /// that returns pane focus to its default has to be told that the default is
    /// different when the window is narrow — otherwise opening or refreshing a
    /// database would quietly push the graph off screen.
    private func preferSchemaPaneWhenCompact() {
        guard workspaceCompactLayout.isCompact else { return }
        guard let schemaSide = side(containing: .schema) else { return }
        activePaneSide = schemaSide
    }

    private func rememberRecentDatabase(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        var urls = recentDatabaseURLs.filter { $0 != normalizedURL }
        urls.insert(normalizedURL, at: 0)
        recentDatabaseURLs = Array(urls.prefix(Self.maxRecentDatabaseCount))
        userDefaults.set(recentDatabaseURLs.map(\.path), forKey: Self.recentDatabaseStorageKey)
    }

    private func presentExportPanel(defaultName: String, format: DataTransferFormat, message: String, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.message = message
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.begin { response in completion(response == .OK ? panel.url : nil) }
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
        schemaReview = nil
        historicalExplanationArtifact = nil
        historicalReplayPointID = nil
        historicalExplanationURL = nil
        schemaReviewChanges = [:]
        schemaReviewEdgeChanges = [:]
        schemaReviewRevision &+= 1
        records.reset()
        records.catalog = snapshot
        records.relationships = RecordAccess.relationships(catalog: snapshot)
        // Count constraints in the complete catalog, not column-pair edges or
        // currently visible neighbours. Composite and self-referencing keys count once.
        graphRelationCounts = records.relationships.reduce(into: [:]) { counts, relation in
            let source = relation.sourceDescriptor?.id ?? relation.sourceTable.displayName
            let target = relation.targetDescriptor?.id ?? relation.targetTable.displayName
            for tableID in Set([source, target]) { counts[tableID, default: 0] += 1 }
        }
        let localURL = (documentURL ?? target.fileURL)?.standardizedFileURL
        let isSameDocument = databaseTarget == target && databaseURL == localURL
        if !isSameDocument { initializedGraphViewportDocument = nil }
        if !isSameDocument {
            automationGroupHints = nil
            automationFocusCommand = nil
            automationViewportCommand = nil
            automationVisibleTableIDs = nil
        }
        databaseTarget = target
        databaseURL = localURL
        if !isSameDocument {
            graphNodeSizeMetric = GraphNodeSizeMetric(rawValue:
                userDefaults.string(forKey: graphNodeSizeStorageKey(for: target)) ??
                userDefaults.string(forKey: Self.graphNodeSizeMetricKey) ?? "") ?? .uniform
        }
        databaseCapabilities = Self.capabilities(for: target)
        if !target.isMigrationModel {
            migrationSet = nil
            selectedMigrationVersion = nil
            migrationReplaySummary = nil
            migrationDiagnostics = []
        }
        // A schema-only model has nothing for the SQL pane to run against. Each
        // pane takes whichever of the remaining kinds the other one does not
        // hold, so replacing the query pane cannot leave both showing the same
        // thing — which would also strand `preferSchemaPaneWhenCompact`.
        if !databaseCapabilities.canRunQueries {
            if leftPane.kind == .query {
                leftPane = WorkspacePaneState(kind: rightPane.kind == .schema ? .tables : .schema)
            }
            if rightPane.kind == .query {
                rightPane = WorkspacePaneState(kind: leftPane.kind == .schema ? .tables : .schema)
            }
        }
        tableDescriptors = Dictionary(uniqueKeysWithValues: snapshot.descriptors.map { ($0.name, $0) })
        tables = snapshot.descriptors.map(\.summary)
        graph = snapshot.graph
        var sidecar: SchemaSidecar
        if let url = databaseURL {
            schemaMetadataState.reload(for: url, descriptors: snapshot.descriptors)
            sidecar = schemaMetadataState.sidecar
        } else {
            schemaMetadataState = SchemaMetadataState()
            sidecar = .empty
        }
        // Descriptions carried by the source itself (COMMENT ON in migrations)
        // fill gaps only; an authored sidecar always wins.
        for (tableName, source) in snapshot.sourceDescriptions {
            var existing = sidecar.tables[tableName] ?? SchemaSidecar.TableDescription()
            if existing.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                existing.description = source.description
            }
            for (columnName, text) in source.columns where existing.columns[columnName] == nil {
                existing.columns[columnName] = text
            }
            sidecar.tables[tableName] = existing
        }
        schemaSidecar = sidecar
        configureRecordMappings(schemaSidecar)
        updateGraphGrouping()
        graphLayout.reset(for: snapshot.graph)
        restorePersistedGraphLayoutIfAvailable(for: target, graph: snapshot.graph)
        selectedGraphNodeID = nil
        expandedGraphNodeIDs = []
        floatingDetailsCardTableID = nil
        floatingDetailsCardPosition = nil
        showAllGraphTableCards = false
        queryWorkspace.loadSavedQueries(for: target)
        if !isSameDocument {
            // Only a genuinely new document returns pane focus to its default.
            // Refreshing the open one leaves the user where they were — which
            // matters most while compact, where focus decides the only pane
            // on screen.
            activePaneSide = .right
            preferSchemaPaneWhenCompact()
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
            if databaseCapabilities.canBrowseRows {
                Task { await replacement.reload() }
            }
            return replacement
        }
        activeTabID = openTabs.last?.id
        if let localURL { rememberRecentDatabase(localURL) }
        if !isSameDocument { markAutomationViewChanged() }
    }

    private func updateGraphGrouping() {
        var groupingSidecar = schemaSidecar
        if let automationGroupHints {
            groupingSidecar.clusters = automationGroupHints + schemaSidecar.clusters
        }
        graphGrouping = GraphGrouping.resolve(graph: graph, descriptors: tableDescriptors, sidecar: groupingSidecar)
        graphLayout.setClusterHints(graphGrouping.nodeToGroup)
    }

    public func openSchemaReview(url: URL) async {
        do {
            let review = try SchemaReviewDocument.load(url)
            closeDatabase()
            let generation = openGeneration
            await pendingDatabaseClose?.value
            guard generation == openGeneration else { return }
            databaseURL = url
            applySchemaReview(review, preservingContext: false)
            if review.proposal != nil { schemaPreviewFileStamp = try? PreviewFileStamp(url) }
            rememberRecentDatabase(url)
        } catch { presentedError = SQLiteUserError.from(error) }
    }

    /// Opens only the schema and explicitly captured values in a saved explanation.
    /// This workspace has no live database target and cannot run a query.
    public func openHistoricalExplanation(_ artifact: HistoricalExplanationArtifact, from url: URL? = nil) {
        do {
            try artifact.validate()
            closeDatabase()
            let captured = artifact.capturedAt.formatted(.iso8601)
            let review = SchemaReviewDocument(
                title: artifact.title,
                baseRef: "Historical capture",
                headRef: captured,
                before: artifact.schema,
                after: artifact.schema,
                notes: ["historical-explanation", "Captured at \(captured). Row values appear only when they were explicitly included in the saved explanation."]
            )
            applySchemaReview(review, preservingContext: false)
            historicalExplanationArtifact = artifact
            historicalReplayPointID = nil
            historicalExplanationURL = url?.standardizedFileURL
            if let firstTable = artifact.schema.tables.first { selectGraphNode(firstTable.id) }
            databaseURL = nil
            databaseTarget = nil
            databaseCapabilities = .none
        } catch {
            presentedError = SQLiteUserError.from(error)
        }
    }

    /// Changes the captured pane contents when offline historical replay advances.
    /// Unknown IDs clear the frame so stale evidence is never shown for another point.
    public func selectHistoricalExplanationPoint(externalPointID: String?) {
        guard let externalPointID else {
            historicalReplayPointID = nil
            return
        }
        guard historicalExplanationArtifact?.points.contains(where: { $0.id == externalPointID }) == true else {
            historicalReplayPointID = nil
            return
        }
        historicalReplayPointID = externalPointID
    }

    private func applySchemaReview(_ review: SchemaReviewDocument, preservingContext: Bool) {
        let previousLayout = preservingContext ? graphLayout.snapshot(for: graph) : nil
        let changes = review.changes, relations = review.relationChanges
        schemaReview = review
        historicalExplanationArtifact = nil
        historicalReplayPointID = nil
        historicalExplanationURL = nil
        schemaReviewChanges = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        schemaReviewEdgeChanges = Dictionary(uniqueKeysWithValues: relations.flatMap { change in
            change.relation.sourceColumns.indices.map { (change.graphID + ":\($0)", change.kind) }
        })
        schemaReviewRevision &+= 1
        tableDescriptors = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0.unionTable.descriptor) })
        tables = changes.map { $0.unionTable.descriptor.summary }
        let newGraph = review.graph
        if graph != newGraph { graph = newGraph }
        graphRelationCounts = [:]
        for versions in Dictionary(grouping: relations, by: { $0.relation.id }).values {
            for id in Set(versions.flatMap { [$0.relation.source, $0.relation.target] }) { graphRelationCounts[id, default: 0] += 1 }
        }
        updateGraphGrouping()
        if let previousLayout {
            graphLayout.restore(previousLayout, for: graph, presentation: showAllGraphTableCards ? .allCards : .compact,
                                descriptorLookup: { self.tableDescriptors[$0] })
        } else { graphLayout.reset(for: graph) }
        let ids = Set(changes.map(\.id))
        expandedGraphNodeIDs.formIntersection(ids)
        selectedGraphNodeIDs.formIntersection(ids)
        // A review opens on every change at once; choosing a table narrows it. A preview
        // reload keeps the reader's choice while that table still exists.
        if !preservingContext || (selectedGraphNodeID.map({ !ids.contains($0) }) ?? false) {
            clearGraphSelection()
        }
        // Row bounds are unavailable; recompute existing field/relation filters.
        if graphTableFilter.isActive { Task { await applyGraphFilter(graphTableFilter) } }
    }

    /// The view polls file metadata, decoding only when an atomic preview write changes it.
    public func refreshSchemaPreviewIfChanged(force: Bool = false) {
        guard schemaReview?.proposal != nil, let databaseURL else { return }
        do {
            let stamp = try PreviewFileStamp(databaseURL)
            guard force || stamp != schemaPreviewFileStamp else { return }
            schemaPreviewFileStamp = stamp
            let next = try SchemaReviewDocument.load(databaseURL)
            guard next.proposal != nil else { throw SchemaReviewError.invalid("The preview file was replaced by an actual comparison. Open that comparison separately.") }
            applySchemaReview(next, preservingContext: true)
            schemaPreviewReloadError = nil
        } catch {
            let message = error.localizedDescription
            if schemaPreviewReloadError != message { schemaPreviewReloadError = message }
        }
    }

    private struct PreviewFileStamp: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
        init(_ url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = values[.modificationDate] as? Date ?? .distantPast
            size = (values[.size] as? NSNumber)?.uint64Value ?? 0
            inode = (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    public func presentSchemaComparison() {
        guard schemaComparisonTask == nil else { return }
        let comparisonID = UUID()
        schemaComparisonID = comparisonID
        let generation = openGeneration
        schemaComparisonTask = Task { @MainActor in
            defer {
                if schemaComparisonID == comparisonID {
                    schemaComparisonTask = nil
                    schemaComparisonID = nil
                }
            }
            guard let beforeURL = await chooseComparisonFile(title: "Choose the before database"),
                  !Task.isCancelled, generation == openGeneration,
                  let afterURL = await chooseComparisonFile(title: "Choose the after database"),
                  !Task.isCancelled, generation == openGeneration else { return }
            do {
                documentOpenProgress = "Reading before schema…"
                let before = try await SchemaReviewCapture.snapshot(document: beforeURL)
                guard generation == openGeneration else { return }
                documentOpenProgress = "Reading after schema…"
                let after = try await SchemaReviewCapture.snapshot(document: afterURL)
                guard generation == openGeneration else { return }
                documentOpenProgress = nil
                let review = SchemaReviewDocument(title: "\(beforeURL.lastPathComponent) → \(afterURL.lastPathComponent)",
                    baseRef: beforeURL.lastPathComponent, headRef: afterURL.lastPathComponent, before: before, after: after)
                try review.validate()
                let panel = NSSavePanel()
                panel.title = "Save Schema Comparison"
                panel.nameFieldStringValue = "Database changes.sgreview"
                panel.allowedContentTypes = [UTType(filenameExtension: "sgreview") ?? .json]
                panel.allowsOtherFileTypes = false
                guard await panel.begin() == .OK, let url = panel.url, generation == openGeneration else { return }
                try Task.checkCancellation()
                try review.write(to: url)
                schemaComparisonTask = nil
                schemaComparisonID = nil
                await openSchemaReview(url: url)
            } catch {
                guard generation == openGeneration, !Task.isCancelled else { return }
                documentOpenProgress = nil
                presentedError = SQLiteUserError.from(error)
            }
        }
    }

    private func chooseComparisonFile(title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let filter = DatabaseDocumentOpenPanelDelegate(extensions: DatabaseDocument.sqliteExtensions.union(DatabaseDocument.otherExtensions))
        panel.delegate = filter
        let response = await panel.begin()
        return withExtendedLifetime(filter) { response == .OK ? panel.url : nil }
    }

    private func graphLayoutStorageKey(for url: URL) -> String {
        graphLayoutStorageKey(for: .sqlite(url))
    }

    private func graphLayoutStorageKey(for target: DatabaseTarget) -> String {
        "SQLiteGraphStudio.graph-layout.v\(Self.graphLayoutStorageVersion).\(target.stableStorageKey)"
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

        if persistedLayout.placementVersion != currentGraphPlacementVersion {
            // A prior build saved older placement coordinates. Recreate the
            // current community layout while retaining deliberate drag pins.
            graphLayout.restore(
                GraphLayoutSnapshot(positions: [:], pinnedPositions: persistedLayout.snapshot.pinnedPositions),
                for: graph,
                presentation: .compact,
                descriptorLookup: { [tableDescriptors] in tableDescriptors[$0] }
            )
            if graph.nodes.count <= GraphLayoutModel.largeGraphOverviewThreshold {
                graphLayout.stabilize(
                    graph: graph, presentation: .compact,
                    descriptorLookup: { [tableDescriptors] in tableDescriptors[$0] },
                    nodeSizeLookup: { [tableDescriptors] id in
                        GraphCardLayout.nodeSize(title: graph.node(id: id)?.title ?? id,
                                                 descriptor: tableDescriptors[id], style: .collapsed)
                    }
                )
            }
            persistCurrentGraphLayout()
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

private let currentGraphPlacementVersion = 4

private struct PersistedGraphLayout: Codable {
    let placementVersion: Int?
    let positions: [String: PersistedPoint]
    let pinnedPositions: [String: PersistedPoint]

    init(snapshot: GraphLayoutSnapshot) {
        placementVersion = currentGraphPlacementVersion
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
