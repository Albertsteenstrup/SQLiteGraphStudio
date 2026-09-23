import Foundation

/// A privacy-limited snapshot of the top-level workspaces that can be rebuilt on
/// the next launch. Query output, row values, connection configurations, and
/// credentials are deliberately excluded.
public struct WorkspaceRestorationSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var tabs: [WorkspaceTabRestorationState]
    public var activeTabID: UUID?

    public init(version: Int = Self.currentVersion, tabs: [WorkspaceTabRestorationState], activeTabID: UUID?) {
        self.version = version
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

public struct WorkspaceTabRestorationState: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: WorkspaceTabKind
    public var title: String
    /// The selected document path only. A live PostgreSQL endpoint is never
    /// serialized as a connection configuration.
    public var sourceDocumentPath: String?
    public var session: WorkspaceSessionRestorationState

    public init(
        id: UUID,
        kind: WorkspaceTabKind,
        title: String,
        sourceDocumentPath: String?,
        session: WorkspaceSessionRestorationState
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sourceDocumentPath = sourceDocumentPath
        self.session = session
    }
}

public struct WorkspaceSessionRestorationState: Codable, Sendable, Equatable {
    public var leftPane: PaneContentKind
    public var rightPane: PaneContentKind
    public var activePane: String
    public var maximizedPane: String?
    public var splitFraction: Double
    public var graphZoom: Double
    public var graphPanX: Double
    public var graphPanY: Double
    public var selectedTableIDs: [String]
    public var focusedTableID: String?
    public var expandedTableIDs: [String]
    public var showAllTableCards: Bool
    public var graphFilter: WorkspaceGraphFilterState
    public var openTables: [WorkspaceTableRestorationState]
    public var activeTableName: String?
    public var unsavedQueryDrafts: [WorkspaceQueryDraft]
    public var activeQueryID: UUID?
    /// The selected migration step for a schema-only source. Older snapshots omit it.
    public var selectedMigrationVersion: String?

    public init(
        leftPane: PaneContentKind = .schema,
        rightPane: PaneContentKind = .tables,
        activePane: String = WorkspacePaneSide.right.rawValue,
        maximizedPane: String? = nil,
        splitFraction: Double = 0.6,
        graphZoom: Double = 1,
        graphPanX: Double = 0,
        graphPanY: Double = 0,
        selectedTableIDs: [String] = [],
        focusedTableID: String? = nil,
        expandedTableIDs: [String] = [],
        showAllTableCards: Bool = false,
        graphFilter: WorkspaceGraphFilterState = .init(),
        openTables: [WorkspaceTableRestorationState] = [],
        activeTableName: String? = nil,
        unsavedQueryDrafts: [WorkspaceQueryDraft] = [],
        activeQueryID: UUID? = nil,
        selectedMigrationVersion: String? = nil
    ) {
        self.leftPane = leftPane
        self.rightPane = rightPane
        self.activePane = activePane
        self.maximizedPane = maximizedPane
        self.splitFraction = splitFraction
        self.graphZoom = graphZoom
        self.graphPanX = graphPanX
        self.graphPanY = graphPanY
        self.selectedTableIDs = selectedTableIDs
        self.focusedTableID = focusedTableID
        self.expandedTableIDs = expandedTableIDs
        self.showAllTableCards = showAllTableCards
        self.graphFilter = graphFilter
        self.openTables = openTables
        self.activeTableName = activeTableName
        self.unsavedQueryDrafts = unsavedQueryDrafts
        self.activeQueryID = activeQueryID
        self.selectedMigrationVersion = selectedMigrationVersion
    }
}

public struct WorkspaceGraphFilterState: Codable, Sendable, Equatable {
    public var minimumFields: Int?
    public var maximumFields: Int?
    public var minimumRows: Int?
    public var maximumRows: Int?
    public var minimumRelations: Int?
    public var maximumRelations: Int?

    public init(
        minimumFields: Int? = nil,
        maximumFields: Int? = nil,
        minimumRows: Int? = nil,
        maximumRows: Int? = nil,
        minimumRelations: Int? = nil,
        maximumRelations: Int? = nil
    ) {
        self.minimumFields = minimumFields
        self.maximumFields = maximumFields
        self.minimumRows = minimumRows
        self.maximumRows = maximumRows
        self.minimumRelations = minimumRelations
        self.maximumRelations = maximumRelations
    }

    public init(_ filter: GraphTableFilter) {
        self.init(
            minimumFields: filter.minimumFields,
            maximumFields: filter.maximumFields,
            minimumRows: filter.minimumRows,
            maximumRows: filter.maximumRows,
            minimumRelations: filter.minimumRelations,
            maximumRelations: filter.maximumRelations
        )
    }

    public var filter: GraphTableFilter {
        GraphTableFilter(
            minimumFields: minimumFields,
            maximumFields: maximumFields,
            minimumRows: minimumRows,
            maximumRows: maximumRows,
            minimumRelations: minimumRelations,
            maximumRelations: maximumRelations
        )
    }
}

public struct WorkspaceTableRestorationState: Codable, Sendable, Equatable {
    public var tableName: String
    public var searchText: String
    public var filters: [WorkspaceColumnFilterState]
    public var sortColumn: String?
    public var sortDirection: String?
    public var offset: Int
    public var limit: Int

    public init(
        tableName: String,
        searchText: String,
        filters: [WorkspaceColumnFilterState],
        sortColumn: String?,
        sortDirection: String?,
        offset: Int,
        limit: Int
    ) {
        self.tableName = tableName
        self.searchText = searchText
        self.filters = filters
        self.sortColumn = sortColumn
        self.sortDirection = sortDirection
        self.offset = offset
        self.limit = limit
    }
}

public struct WorkspaceColumnFilterState: Codable, Sendable, Equatable {
    public var columnName: String
    public var value: String
    public var comparison: String
    public var upperValue: String?

    public init(columnName: String, value: String, comparison: String, upperValue: String?) {
        self.columnName = columnName
        self.value = value
        self.comparison = comparison
        self.upperValue = upperValue
    }
}

public struct WorkspaceQueryDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var sqlText: String
    public var selectedOutput: String

    public init(id: UUID, title: String, sqlText: String, selectedOutput: String) {
        self.id = id
        self.title = title
        self.sqlText = sqlText
        self.selectedOutput = selectedOutput
    }
}

/// Stores workspace restoration data under Application Support using owner-only
/// permissions. The snapshot is intentionally independent of database credentials
/// and query output so a crash recovery file contains browsing intent only.
public struct WorkspaceRestorationStore: Sendable {
    public static let defaultStore = WorkspaceRestorationStore(fileURL: Self.defaultFileURL())

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func load() -> WorkspaceRestorationSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maximumFileSize,
              let snapshot = try? JSONDecoder().decode(WorkspaceRestorationSnapshot.self, from: data),
              Self.isSupported(snapshot) else {
            return nil
        }
        return snapshot
    }

    public func save(_ snapshot: WorkspaceRestorationSnapshot) throws {
        guard Self.isSupported(snapshot) else {
            throw WorkspaceRestorationStoreError.invalidSnapshot
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumFileSize else {
            throw WorkspaceRestorationStoreError.snapshotTooLarge
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static let maximumFileSize = 8 * 1_024 * 1_024
    private static let maximumTabs = 48
    private static let maximumTablesPerTab = 128
    private static let maximumDraftsPerTab = 64
    private static let maximumStringLength = 1_000_000

    private static func isSupported(_ snapshot: WorkspaceRestorationSnapshot) -> Bool {
        guard snapshot.version == WorkspaceRestorationSnapshot.currentVersion,
              snapshot.tabs.count <= maximumTabs,
              Set(snapshot.tabs.map(\.id)).count == snapshot.tabs.count,
              snapshot.activeTabID.map({ id in snapshot.tabs.contains(where: { $0.id == id }) }) ?? true else { return false }

        return snapshot.tabs.allSatisfy { tab in
            guard tab.title.count <= 500,
                  (tab.sourceDocumentPath?.count ?? 0) <= maximumStringLength,
                  tab.session.openTables.count <= maximumTablesPerTab,
                  tab.session.unsavedQueryDrafts.count <= maximumDraftsPerTab,
                  Set(tab.session.openTables.map(\.tableName)).count == tab.session.openTables.count,
                  tab.session.openTables.allSatisfy({ $0.tableName.count <= 500 && $0.searchText.count <= 10_000 && $0.filters.count <= 128 }),
                  tab.session.unsavedQueryDrafts.allSatisfy({ $0.title.count <= 500 && $0.sqlText.count <= maximumStringLength }),
                  tab.session.selectedTableIDs.count <= 2_000,
                  tab.session.expandedTableIDs.count <= 2_000,
                  tab.session.selectedTableIDs.allSatisfy({ $0.count <= 1_000 }),
                  tab.session.expandedTableIDs.allSatisfy({ $0.count <= 1_000 }) else { return false }
            return true
        }
    }

    private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("SQLiteGraphStudio", isDirectory: true)
            .appendingPathComponent("workspace-restoration.json", isDirectory: false)
    }
}

public enum WorkspaceRestorationStoreError: Error, LocalizedError, Sendable {
    case invalidSnapshot
    case snapshotTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "The workspace restoration snapshot is invalid or exceeds its supported limits."
        case .snapshotTooLarge: "The workspace restoration snapshot is too large to save."
        }
    }
}
