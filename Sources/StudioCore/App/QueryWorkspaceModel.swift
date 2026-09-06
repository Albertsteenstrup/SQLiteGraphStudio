import Foundation
import Observation

public struct QueryDocument: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var sqlText: String
    /// Original editor text that produced the currently displayed result.
    public var executedSQL: String?
    public var result: QueryResult
    public var isRunning: Bool
    public var errorMessage: String?
    public var isSaved: Bool
    public var explainPlan: [ExplainPlanRow]
    public var selectedOutput: QueryOutputKind

    public init(
        id: UUID = UUID(),
        title: String,
        sqlText: String,
        result: QueryResult = .empty,
        executedSQL: String? = nil,
        isRunning: Bool = false,
        errorMessage: String? = nil,
        isSaved: Bool = false,
        explainPlan: [ExplainPlanRow] = [],
        selectedOutput: QueryOutputKind = .results
    ) {
        self.id = id
        self.title = title
        self.sqlText = sqlText
        self.result = result
        self.executedSQL = executedSQL
        self.isRunning = isRunning
        self.errorMessage = errorMessage
        self.isSaved = isSaved
        self.explainPlan = explainPlan
        self.selectedOutput = selectedOutput
    }
}

public enum QueryOutputKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case results
    case plan

    public var id: String { rawValue }
}

@MainActor
@Observable
public final class QueryWorkspaceModel {
    public var queries: [QueryDocument] = []
    public var activeQueryID: UUID?
    public var history: [QueryHistoryEntry] = []
    public var timeoutSeconds: TimeInterval = 30

    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var currentTarget: DatabaseTarget?
    private var currentDatabaseStorageKey: String?
    private var currentHistoryStorageKey: String?
    private var requestTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private static let maxHistoryCount = 7

    public init(
        databaseService: DatabaseService,
        userDefaults: UserDefaults = .standard
    ) {
        self.databaseService = databaseService
        self.userDefaults = userDefaults
    }

    public var activeQuery: QueryDocument? {
        guard let activeQueryIndex else { return nil }
        return queries[activeQueryIndex]
    }

    public var hasQueries: Bool {
        !queries.isEmpty
    }

    public func loadSavedQueries(for databaseURL: URL?) {
        loadSavedQueries(for: databaseURL.map { .sqlite($0.standardizedFileURL) })
    }

    public func loadSavedQueries(for target: DatabaseTarget?) {
        cancelAllExecutions()
        currentTarget = target
        currentDatabaseStorageKey = target.map(storageKey(for:))
        currentHistoryStorageKey = target.map(historyStorageKey(for:))
        loadHistory()

        guard let currentDatabaseStorageKey,
              let data = userDefaults.data(forKey: currentDatabaseStorageKey),
              let persistedQueries = try? JSONDecoder().decode([PersistedQueryDocument].self, from: data)
        else {
            queries = [makeDefaultQuery()]
            activeQueryID = queries.first?.id
            return
        }

        queries = persistedQueries.map {
            QueryDocument(
                id: $0.id,
                title: $0.title,
                sqlText: $0.sqlText,
                isSaved: true
            )
        }

        if queries.isEmpty {
            queries = [makeDefaultQuery()]
        }

        activeQueryID = queries.first?.id
    }

    public func reset() {
        cancelAllExecutions()
        queries = []
        activeQueryID = nil
        currentTarget = nil
        currentDatabaseStorageKey = nil
        currentHistoryStorageKey = nil
        history = []
        requestTokens.removeAll()
    }

    @discardableResult
    public func createQuery(
        title: String? = nil,
        sqlText: String? = nil,
        activate: Bool = true,
        runImmediately: Bool = false,
        isSaved: Bool = false
    ) -> QueryDocument {
        let query = QueryDocument(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : nextUntitledName(),
            sqlText: sqlText ?? Self.defaultSQL(for: currentTarget),
            isSaved: isSaved
        )
        queries.append(query)
        if activate {
            activeQueryID = query.id
        }
        if isSaved {
            persistSavedQueries()
        }
        if runImmediately {
            run(queryID: query.id)
        }
        return query
    }

    public func createTopRowsQuery(for descriptor: TableDescriptor) {
        createQuery(
            title: "\(descriptor.name) Top 10",
            sqlText: """
            SELECT *
            FROM \(descriptor.tableDataSQLSource)
            LIMIT 10;
            """,
            activate: true,
            runImmediately: true,
            isSaved: false
        )
    }

    public func closeQuery(id: UUID) {
        cancelExecution(for: id)
        queries.removeAll { $0.id == id }
        requestTokens[id] = nil

        if queries.isEmpty {
            queries = [makeDefaultQuery()]
        }

        if activeQueryID == id {
            activeQueryID = queries.last?.id
        }

        persistSavedQueries()
    }

    public func selectQuery(id: UUID) {
        guard queries.contains(where: { $0.id == id }) else { return }
        activeQueryID = id
    }

    public func updateActiveTitle(_ title: String) {
        guard let activeQueryIndex else { return }
        queries[activeQueryIndex].title = title
        if queries[activeQueryIndex].isSaved {
            persistSavedQueries()
        }
    }

    public func updateTitle(_ title: String, for queryID: UUID) {
        guard let index = queries.firstIndex(where: { $0.id == queryID }) else { return }
        queries[index].title = title
        if queries[index].isSaved {
            persistSavedQueries()
        }
    }

    public func updateActiveSQL(_ sqlText: String) {
        guard let activeQueryIndex else { return }
        queries[activeQueryIndex].sqlText = sqlText
        if queries[activeQueryIndex].isSaved {
            persistSavedQueries()
        }
    }

    public func setActiveQuerySaved(_ isSaved: Bool) {
        guard let activeQueryIndex else { return }

        if isSaved, queries[activeQueryIndex].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queries[activeQueryIndex].title = nextUntitledName()
        }

        queries[activeQueryIndex].isSaved = isSaved
        persistSavedQueries()
    }

    public func run() {
        guard let queryID = activeQuery?.id else { return }
        run(queryID: queryID)
    }

    public func explain() {
        guard let queryID = activeQuery?.id else { return }
        explain(queryID: queryID)
    }

    public func stop() {
        guard let queryID = activeQuery?.id else { return }
        cancelExecution(for: queryID)
        if let index = index(for: queryID) {
            queries[index].isRunning = false
            queries[index].errorMessage = "Query stopped."
        }
    }

    public func stopAll() {
        cancelAllExecutions()
        for index in queries.indices where queries[index].isRunning {
            queries[index].isRunning = false
            queries[index].errorMessage = "Query stopped."
        }
    }

    private func cancelExecution(for queryID: UUID) {
        requestTokens[queryID] = nil
        runningTasks.removeValue(forKey: queryID)?.cancel()
    }

    private func cancelAllExecutions() {
        requestTokens.removeAll()
        let tasks = runningTasks.values
        runningTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    public func selectActiveOutput(_ output: QueryOutputKind) {
        guard let activeQueryIndex else { return }
        queries[activeQueryIndex].selectedOutput = output
    }

    public func removeHistoryEntry(id: UUID) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    public func clearHistory() {
        history = []
        persistHistory()
    }

    private func run(queryID: UUID) {
        guard let queryIndex = index(for: queryID) else { return }

        cancelExecution(for: queryID)
        let requestToken = UUID()
        requestTokens[queryID] = requestToken

        queries[queryIndex].isRunning = true
        queries[queryIndex].errorMessage = nil
        let sqlText = queries[queryIndex].sqlText
        let title = queries[queryIndex].title
        let clock = ContinuousClock()
        let startedAt = clock.now

        let timeout = timeoutSeconds
        runningTasks[queryID] = Task { [weak self, databaseService] in
            do {
                let result = try await databaseService.executeReadOnlyQuery(sql: sqlText, timeoutSeconds: timeout)
                let elapsed = startedAt.duration(to: clock.now).milliseconds
                guard let self, self.requestTokens[queryID] == requestToken,
                      let queryIndex = index(for: queryID)
                else {
                    return
                }
                runningTasks[queryID] = nil
                queries[queryIndex].result = result
                queries[queryIndex].executedSQL = sqlText
                queries[queryIndex].isRunning = false
                queries[queryIndex].selectedOutput = .results
                recordHistory(
                    QueryHistoryEntry(
                        title: title,
                        sqlText: sqlText,
                        durationMilliseconds: elapsed,
                        rowCount: result.rows.count,
                        succeeded: true,
                        message: result.isTruncated ? "Showing first \(result.rowLimit) rows" : nil
                    )
                )
            } catch {
                let elapsed = startedAt.duration(to: clock.now).milliseconds
                guard let self, self.requestTokens[queryID] == requestToken,
                      let queryIndex = index(for: queryID)
                else {
                    return
                }
                runningTasks[queryID] = nil
                let message = error is CancellationError ? "Query cancelled." : SQLiteUserError.from(error).message
                queries[queryIndex].errorMessage = message
                queries[queryIndex].isRunning = false
                recordHistory(
                    QueryHistoryEntry(
                        title: title,
                        sqlText: sqlText,
                        durationMilliseconds: elapsed,
                        rowCount: 0,
                        succeeded: false,
                        message: message
                    )
                )
            }
        }
    }

    private func explain(queryID: UUID) {
        guard let queryIndex = index(for: queryID) else { return }

        cancelExecution(for: queryID)
        let requestToken = UUID()
        requestTokens[queryID] = requestToken

        queries[queryIndex].isRunning = true
        queries[queryIndex].errorMessage = nil
        let sqlText = queries[queryIndex].sqlText

        let timeout = timeoutSeconds
        runningTasks[queryID] = Task { [weak self, databaseService] in
            do {
                let plan = try await databaseService.explainQueryPlan(sql: sqlText, timeoutSeconds: timeout)
                guard let self, self.requestTokens[queryID] == requestToken,
                      let queryIndex = index(for: queryID)
                else {
                    return
                }
                runningTasks[queryID] = nil
                queries[queryIndex].explainPlan = plan
                queries[queryIndex].selectedOutput = .plan
                queries[queryIndex].isRunning = false
            } catch {
                guard let self, self.requestTokens[queryID] == requestToken,
                      let queryIndex = index(for: queryID)
                else {
                    return
                }
                runningTasks[queryID] = nil
                queries[queryIndex].errorMessage = error is CancellationError ? "Query cancelled." : SQLiteUserError.from(error).message
                queries[queryIndex].isRunning = false
            }
        }
    }

    private var activeQueryIndex: Int? {
        if let activeQueryID,
           let index = queries.firstIndex(where: { $0.id == activeQueryID }) {
            return index
        }
        guard !queries.isEmpty else { return nil }
        return queries.startIndex
    }

    private func index(for queryID: UUID) -> Int? {
        queries.firstIndex(where: { $0.id == queryID })
    }

    private func nextUntitledName() -> String {
        let existingTitles = Set(queries.map(\.title))
        var counter = 1
        while existingTitles.contains("Query \(counter)") {
            counter += 1
        }
        return "Query \(counter)"
    }

    private func makeDefaultQuery() -> QueryDocument {
        QueryDocument(title: nextUntitledName(), sqlText: Self.defaultSQL(for: currentTarget))
    }

    private func persistSavedQueries() {
        guard let currentDatabaseStorageKey else { return }

        let savedQueries = queries
            .filter(\.isSaved)
            .map(PersistedQueryDocument.init)

        if savedQueries.isEmpty {
            userDefaults.removeObject(forKey: currentDatabaseStorageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(savedQueries) else { return }
        userDefaults.set(data, forKey: currentDatabaseStorageKey)
    }

    private func loadHistory() {
        guard let currentHistoryStorageKey,
              let data = userDefaults.data(forKey: currentHistoryStorageKey),
              let entries = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data)
        else {
            history = []
            return
        }

        history = Array(entries.prefix(Self.maxHistoryCount))
    }

    private func recordHistory(_ entry: QueryHistoryEntry) {
        history.insert(entry, at: 0)
        history = Array(history.prefix(Self.maxHistoryCount))
        persistHistory()
    }

    private func persistHistory() {
        guard let currentHistoryStorageKey,
              let data = try? JSONEncoder().encode(history)
        else {
            return
        }
        userDefaults.set(data, forKey: currentHistoryStorageKey)
    }

    private func storageKey(for databaseURL: URL) -> String {
        "SQLiteGraphStudio.saved-queries.\(databaseURL.path)"
    }

    private func storageKey(for target: DatabaseTarget) -> String {
        switch target {
        case .sqlite(let url):
            return storageKey(for: url)
        case .postgres:
            return "SQLiteGraphStudio.saved-queries.\(target.stableStorageKey)"
        }
    }

    private func historyStorageKey(for databaseURL: URL) -> String {
        "SQLiteGraphStudio.query-history.\(databaseURL.path)"
    }

    private func historyStorageKey(for target: DatabaseTarget) -> String {
        switch target {
        case .sqlite(let url):
            return historyStorageKey(for: url)
        case .postgres:
            return "SQLiteGraphStudio.query-history.\(target.stableStorageKey)"
        }
    }

    private static func defaultSQL(for target: DatabaseTarget?) -> String {
        if target?.isPostgres == true {
            return """
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name;
            """
        }
        return """
        SELECT name, type
        FROM sqlite_master
        WHERE type IN ('table', 'view')
        ORDER BY name;
        """
    }
}

private struct PersistedQueryDocument: Codable {
    let id: UUID
    let title: String
    let sqlText: String

    init(_ query: QueryDocument) {
        id = query.id
        title = query.title
        sqlText = query.sqlText
    }
}
