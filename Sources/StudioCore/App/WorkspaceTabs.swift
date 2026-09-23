import AppKit
import Observation
import Foundation

/// The purpose of a top-level workspace tab. Its contents remain a normal graph/data split.
public enum WorkspaceTabKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case workspace
    case preview
    case comparison
    case explanation
    case artifact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .workspace: "Workspace"
        case .preview: "Schema Preview"
        case .comparison: "Schema Comparison"
        case .explanation: "Explanation"
        case .artifact: "Artifact"
        }
    }

    public var systemImage: String {
        switch self {
        case .workspace: "square.split.2x1"
        case .preview: "rectangle.dashed.badge.record"
        case .comparison: "rectangle.split.2x1"
        case .explanation: "text.bubble"
        case .artifact: "doc.text"
        }
    }

    static func inferred(for url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "sgpreview": .preview
        case "sgreview": .comparison
        case "sgexplanation": .explanation
        default: .workspace
        }
    }
}

/// A top-level tab owns one browsing session and all of that session's graph, table,
/// record, and query state.
@MainActor
@Observable
public final class WorkspaceTab: Identifiable {
    public let id: UUID
    public let kind: WorkspaceTabKind
    public let session: AppSession
    private let explicitTitle: String?

    public init(
        id: UUID = UUID(),
        kind: WorkspaceTabKind = .workspace,
        title: String? = nil,
        session: AppSession
    ) {
        self.id = id
        self.kind = kind
        self.explicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.session = session
    }

    public var title: String {
        explicitTitle ?? (session.hasOpenDatabase ? session.databaseDisplayName : kind.title)
    }

    public var sourceLabel: String? {
        session.hasOpenDatabase ? session.databaseDisplayName : nil
    }
}

/// Owns the workspaces shown in one application window.
@MainActor
@Observable
public final class WorkspaceTabController {
    public private(set) var tabs: [WorkspaceTab]
    public private(set) var activeTabID: UUID? {
        didSet {
            guard oldValue != activeTabID else { return }
            onActiveTabChanged?(activeTabID)
        }
    }

    @ObservationIgnored private let sessionFactory: () -> AppSession
    @ObservationIgnored public var onActiveTabChanged: (@MainActor (UUID?) -> Void)?
    @ObservationIgnored public var onTabClosed: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var restorationStore: WorkspaceRestorationStore?
    @ObservationIgnored private var restorationSaveTask: Task<Void, Never>?
    @ObservationIgnored private var restorationObservationToken = UUID()
    @ObservationIgnored private var lastSavedRestorationSnapshot: WorkspaceRestorationSnapshot?
    @ObservationIgnored private var isRestoringSnapshot = false

    public init(
        initialSession: AppSession = AppSession(),
        sessionFactory: @escaping () -> AppSession = { AppSession() }
    ) {
        self.sessionFactory = sessionFactory
        let initialTab = WorkspaceTab(session: initialSession)
        self.tabs = [initialTab]
        self.activeTabID = initialTab.id
    }

    public var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    public var activeSession: AppSession? {
        activeTab?.session
    }

    @discardableResult
    public func createTab(
        kind: WorkspaceTabKind = .workspace,
        title: String? = nil,
        session: AppSession? = nil,
        activate shouldActivate: Bool = true
    ) -> WorkspaceTab {
        let candidate = session ?? sessionFactory()
        let ownedSession = tabs.contains { $0.session === candidate } ? makeUnownedSession() : candidate
        let tab = WorkspaceTab(kind: kind, title: title, session: ownedSession)
        tabs.append(tab)
        if shouldActivate {
            activeTabID = tab.id
        }
        return tab
    }

    private func makeUnownedSession() -> AppSession {
        let candidate = sessionFactory()
        guard tabs.contains(where: { $0.session === candidate }) else { return candidate }
        return AppSession()
    }

    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Opens one document in a new tab, preserving every existing workspace.
    @discardableResult
    public func openDocument(_ url: URL, activate shouldActivate: Bool = true) async -> WorkspaceTab {
        let tab = createTab(kind: .inferred(for: url), activate: shouldActivate)
        await tab.session.openDocument(url: url)
        return tab
    }

    /// Opens each incoming document in its own tab. The first new tab remains active.
    @discardableResult
    public func openDocuments(_ urls: [URL], activate shouldActivate: Bool = true) async -> [WorkspaceTab] {
        guard !urls.isEmpty else { return [] }
        let newTabs = urls.map { createTab(kind: .inferred(for: $0), activate: false) }
        if shouldActivate, let first = newTabs.first {
            activeTabID = first.id
        }
        for (tab, url) in zip(newTabs, urls) {
            await tab.session.openDocument(url: url)
        }
        return newTabs
    }

    /// Removes a tab and waits for its database and query work to close before returning.
    public func closeAndWait(_ id: UUID) async {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTab = tabs.remove(at: index)

        if activeTabID == id {
            if tabs.isEmpty {
                let replacement = WorkspaceTab(session: sessionFactory())
                tabs = [replacement]
                activeTabID = replacement.id
            } else {
                activeTabID = tabs[min(index, tabs.count - 1)].id
            }
        }

        onTabClosed?(id)
        await closingTab.session.closeAndWait()
    }

    public func closeAllAndWait() async {
        let existingTabs = tabs
        tabs = []
        activeTabID = nil
        for tab in existingTabs {
            onTabClosed?(tab.id)
            await tab.session.closeAndWait()
        }
    }

    /// Captures the open top-level tabs and their safe browsing state. Database
    /// targets, query results, record values, and speech or presentation state are
    /// omitted. SQL text is retained only for unsaved editor drafts and is never
    /// executed as part of a later restore.
    public func makeRestorationSnapshot() -> WorkspaceRestorationSnapshot {
        let states = tabs.map { tab in
            WorkspaceTabRestorationState(
                id: tab.id,
                kind: tab.kind,
                title: tab.title,
                sourceDocumentPath: restorationDocumentPath(for: tab.session),
                session: restorationState(for: tab.session)
            )
        }
        return WorkspaceRestorationSnapshot(tabs: states, activeTabID: activeTabID)
    }

    /// Rebuilds the saved tabs and browsing state. A missing or unsupported source
    /// leaves its tab available and places a recovery message in the session so the
    /// user can open the moved document again. SQL drafts are loaded into the editor
    /// only; this method never runs them or restores prior query output.
    public func restoreWorkspace(from snapshot: WorkspaceRestorationSnapshot) async {
        guard snapshot.version == WorkspaceRestorationSnapshot.currentVersion else { return }
        restorationSaveTask?.cancel()
        restorationObservationToken = UUID()
        isRestoringSnapshot = true
        defer {
            isRestoringSnapshot = false
            if restorationStore != nil { armRestorationObservation() }
        }

        await closeAllAndWait()

        var restoredTabs: [WorkspaceTab] = []
        var resolvedIDs: [UUID: UUID] = [:]
        var seenIDs = Set<UUID>()
        for savedTab in snapshot.tabs.prefix(48) {
            let id = seenIDs.insert(savedTab.id).inserted ? savedTab.id : UUID()
            if resolvedIDs[savedTab.id] == nil { resolvedIDs[savedTab.id] = id }
            restoredTabs.append(WorkspaceTab(
                id: id,
                kind: savedTab.kind,
                title: savedTab.title,
                session: sessionFactory()
            ))
        }

        if restoredTabs.isEmpty {
            restoredTabs = [WorkspaceTab(session: sessionFactory())]
        }
        tabs = restoredTabs
        activeTabID = snapshot.activeTabID.flatMap { resolvedIDs[$0] } ?? restoredTabs.first?.id

        for (tab, savedTab) in zip(restoredTabs, snapshot.tabs.prefix(restoredTabs.count)) {
            if let path = savedTab.sourceDocumentPath, !path.isEmpty {
                let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
                guard DatabaseDocument.supportedExtensions.contains(sourceURL.pathExtension.lowercased()) else {
                    tab.session.presentedError = SQLiteUserError(
                        kind: .invalidInput,
                        message: "This saved tab points to an unsupported document.",
                        recoverySuggestion: "Choose File > Open Database to select a supported database or workspace document."
                    )
                    await restore(savedTab.session, in: tab.session)
                    continue
                }
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    tab.session.presentedError = SQLiteUserError(
                        kind: .notFound,
                        message: "The saved source \(sourceURL.lastPathComponent) is unavailable.",
                        recoverySuggestion: "Reconnect the drive or choose File > Open Database to locate the source again."
                    )
                    await restore(savedTab.session, in: tab.session)
                    continue
                }
                await tab.session.openDocument(url: sourceURL)
            }
            await restore(savedTab.session, in: tab.session)
        }
    }

    /// Starts observation-based, debounced autosaving. Call after launch restoration
    /// has completed so the seed snapshot is not overwritten by the initial blank tab.
    public func enableAutomaticRestoration(using store: WorkspaceRestorationStore = .defaultStore) {
        restorationStore = store
        lastSavedRestorationSnapshot = store.load()
        let current = makeRestorationSnapshot()
        if current != lastSavedRestorationSnapshot {
            try? store.save(current)
            lastSavedRestorationSnapshot = current
        }
        armRestorationObservation()
    }

    /// Stops background snapshot observation. Call after the final termination
    /// snapshot has been written and before closing sessions.
    public func stopAutomaticRestoration() {
        restorationSaveTask?.cancel()
        restorationSaveTask = nil
        restorationObservationToken = UUID()
        restorationStore = nil
    }

    /// Writes the latest snapshot synchronously for normal application termination.
    /// Autosaving also covers the most recent state if the application exits early.
    public func saveRestorationState() throws {
        try saveRestorationState(to: restorationStore ?? .defaultStore)
    }

    public func saveRestorationState(to store: WorkspaceRestorationStore) throws {
        let snapshot = makeRestorationSnapshot()
        try store.save(snapshot)
        lastSavedRestorationSnapshot = snapshot
    }

    private func armRestorationObservation() {
        guard restorationStore != nil, !isRestoringSnapshot else { return }
        let token = UUID()
        restorationObservationToken = token
        withObservationTracking {
            _ = makeRestorationSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.restorationObservationToken == token,
                      self.restorationStore != nil,
                      !self.isRestoringSnapshot else { return }
                self.armRestorationObservation()
                self.scheduleRestorationSave()
            }
        }
    }

    private func scheduleRestorationSave() {
        restorationSaveTask?.cancel()
        restorationSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, let store = self.restorationStore, !Task.isCancelled else { return }
            let snapshot = self.makeRestorationSnapshot()
            guard snapshot != self.lastSavedRestorationSnapshot else { return }
            do {
                try store.save(snapshot)
                self.lastSavedRestorationSnapshot = snapshot
            } catch {
                // A later observed change or the termination hook will retry.
            }
        }
    }

    private func restorationDocumentPath(for session: AppSession) -> String? {
        guard let url = (session.historicalExplanationURL ?? session.databaseURL)?.standardizedFileURL,
              DatabaseDocument.supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url.path
    }

    private func restorationState(for session: AppSession) -> WorkspaceSessionRestorationState {
        let queryDrafts = session.queryWorkspace.queries.filter { !$0.isSaved }.map { query in
            WorkspaceQueryDraft(
                id: query.id,
                title: query.title,
                sqlText: query.sqlText,
                selectedOutput: query.selectedOutput.rawValue
            )
        }
        let openTables = session.openTabs.map { tab in
            let query = tab.queryState
            return WorkspaceTableRestorationState(
                tableName: tab.descriptor.name,
                searchText: query.searchText,
                filters: query.columnFilters.map {
                    WorkspaceColumnFilterState(
                        columnName: $0.columnName,
                        value: $0.value,
                        comparison: $0.comparison.rawValue,
                        upperValue: $0.upperValue
                    )
                },
                sortColumn: query.sort?.columnName,
                sortDirection: query.sort?.direction.rawValue,
                offset: min(10_000_000, max(0, query.offset)),
                limit: min(1_000, max(1, query.limit))
            )
        }
        let zoom = session.graphZoom.isFinite ? min(8, max(0.1, session.graphZoom)) : 1
        let panX = session.graphPan.width.isFinite ? min(1_000_000, max(-1_000_000, session.graphPan.width)) : 0
        let panY = session.graphPan.height.isFinite ? min(1_000_000, max(-1_000_000, session.graphPan.height)) : 0
        let split = session.workspaceSplitFraction.isFinite ? min(0.75, max(0.25, session.workspaceSplitFraction)) : 0.6
        return WorkspaceSessionRestorationState(
            leftPane: session.leftPane.kind,
            rightPane: session.rightPane.kind,
            activePane: session.activePaneSide.rawValue,
            maximizedPane: session.maximizedPaneSide?.rawValue,
            splitFraction: Double(split),
            graphZoom: Double(zoom),
            graphPanX: Double(panX),
            graphPanY: Double(panY),
            selectedTableIDs: session.selectedGraphNodeIDs.sorted(),
            focusedTableID: session.selectedGraphNodeID,
            expandedTableIDs: session.expandedGraphNodeIDs.sorted(),
            showAllTableCards: session.showAllGraphTableCards,
            graphFilter: WorkspaceGraphFilterState(session.graphTableFilter),
            openTables: openTables,
            activeTableName: session.activeTab?.descriptor.name,
            unsavedQueryDrafts: queryDrafts,
            activeQueryID: session.queryWorkspace.activeQueryID
        )
    }

    private func restore(_ saved: WorkspaceSessionRestorationState, in session: AppSession) async {
        let validTableIDs = Set(session.graph.nodes.map(\.id))
        session.graphZoom = CGFloat(saved.graphZoom.isFinite ? min(8, max(0.1, saved.graphZoom)) : 1)
        session.graphPan = CGSize(
            width: CGFloat(saved.graphPanX.isFinite ? min(1_000_000, max(-1_000_000, saved.graphPanX)) : 0),
            height: CGFloat(saved.graphPanY.isFinite ? min(1_000_000, max(-1_000_000, saved.graphPanY)) : 0)
        )
        session.showAllGraphTableCards = saved.showAllTableCards
        session.restoreGraphFilterWithoutCounting(saved.graphFilter.filter)
        let visibleTableIDs = session.graphVisibleTableIDs.intersection(validTableIDs)
        session.setGraphSelection(Set(saved.selectedTableIDs).intersection(visibleTableIDs))
        if let focusedID = saved.focusedTableID,
           session.selectedGraphNodeIDs.contains(focusedID) {
            session.selectedGraphNodeID = focusedID
        }
        session.expandedGraphNodeIDs = Set(saved.expandedTableIDs).intersection(validTableIDs)

        if session.hasOpenDatabase || session.schemaReview != nil {
            for tableState in saved.openTables {
                guard session.tables.contains(where: { $0.id == tableState.tableName }),
                      let tab = session.openTable(named: tableState.tableName, autoLoad: false) else { continue }
                let filters = tableState.filters.compactMap { state -> ColumnFilter? in
                    guard let comparison = ColumnFilterComparison(rawValue: state.comparison),
                          tab.descriptor.columns.contains(where: { $0.name == state.columnName }) else { return nil }
                    return ColumnFilter(columnName: state.columnName, value: state.value,
                                        comparison: comparison, upperValue: state.upperValue)
                }
                let sort: SortState?
                if let column = tableState.sortColumn,
                   let direction = tableState.sortDirection.flatMap(SortDirection.init(rawValue:)),
                   tab.descriptor.columns.contains(where: { $0.name == column }) {
                    sort = SortState(columnName: column, direction: direction)
                } else {
                    sort = nil
                }
                tab.queryState = TableQueryState(
                    searchText: String(tableState.searchText.prefix(10_000)),
                    columnFilters: filters,
                    sort: sort,
                    offset: min(10_000_000, max(0, tableState.offset)),
                    limit: min(1_000, max(1, tableState.limit))
                )
            }
            if let activeName = saved.activeTableName,
               let activeTable = session.openTabs.first(where: { $0.descriptor.name == activeName }) {
                session.activeTabID = activeTable.id
            }
        }

        let existingSavedQueries = session.queryWorkspace.queries.filter(\.isSaved)
        let drafts = saved.unsavedQueryDrafts.map { draft in
            QueryDocument(
                id: draft.id,
                title: String(draft.title.prefix(500)),
                sqlText: String(draft.sqlText.prefix(1_000_000)),
                selectedOutput: QueryOutputKind(rawValue: draft.selectedOutput) ?? .results
            )
        }
        var restoredQueries = existingSavedQueries + drafts
        if restoredQueries.isEmpty {
            restoredQueries = session.queryWorkspace.queries.filter { !$0.isSaved }.prefix(1).map { $0 }
        }
        session.queryWorkspace.queries = restoredQueries
        let validQueryIDs = Set(restoredQueries.map(\.id))
        if let activeID = saved.activeQueryID, validQueryIDs.contains(activeID) {
            session.queryWorkspace.activeQueryID = activeID
        } else {
            session.queryWorkspace.activeQueryID = drafts.last?.id ?? restoredQueries.first?.id
        }

        // Opening table tabs temporarily moves the table pane into view. Apply the
        // saved split arrangement after rebuilding them so the original layout wins.
        let left = saved.leftPane
        let right = saved.rightPane
        if left != right {
            session.leftPane = WorkspacePaneState(kind: left)
            session.rightPane = WorkspacePaneState(kind: right)
        } else {
            session.leftPane = WorkspacePaneState(kind: .schema)
            session.rightPane = WorkspacePaneState(kind: .tables)
        }
        session.activePaneSide = WorkspacePaneSide(rawValue: saved.activePane) ?? .right
        session.maximizedPaneSide = saved.maximizedPane.flatMap(WorkspacePaneSide.init(rawValue:))
        session.workspaceSplitFraction = CGFloat(saved.splitFraction.isFinite ? min(0.75, max(0.25, saved.splitFraction)) : 0.6)
    }

    /// Opens the native picker and creates one workspace for every selected document.
    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        let documentFilter = DatabaseDocumentOpenPanelDelegate(extensions: DatabaseDocument.supportedExtensions)
        panel.delegate = documentFilter
        panel.title = "Open Database or Workspace"
        panel.message = DatabaseDocument.supportedFormatsDescription
        panel.prompt = "Open"

        let presentingWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        panel.begin { [weak self, documentFilter, weak presentingWindow] response in
            withExtendedLifetime(documentFilter) {
                presentingWindow?.makeKeyAndOrderFront(nil)
                guard response == .OK, let self, !panel.urls.isEmpty else { return }
                Task { await self.openDocuments(panel.urls) }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
