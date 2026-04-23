import Foundation
import Observation

public struct QueryDocument: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var sqlText: String
    public var result: QueryResult
    public var isRunning: Bool
    public var errorMessage: String?
    public var isSaved: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        sqlText: String,
        result: QueryResult = .empty,
        isRunning: Bool = false,
        errorMessage: String? = nil,
        isSaved: Bool = false
    ) {
        self.id = id
        self.title = title
        self.sqlText = sqlText
        self.result = result
        self.isRunning = isRunning
        self.errorMessage = errorMessage
        self.isSaved = isSaved
    }
}

@MainActor
@Observable
public final class QueryWorkspaceModel {
    public var queries: [QueryDocument] = []
    public var activeQueryID: UUID?

    private let databaseService: DatabaseService
    private let userDefaults: UserDefaults
    private var currentDatabaseStorageKey: String?
    private var requestTokens: [UUID: Int] = [:]

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
        requestTokens.removeAll()
        currentDatabaseStorageKey = databaseURL.map(storageKey(for:))

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
        queries = []
        activeQueryID = nil
        currentDatabaseStorageKey = nil
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
            sqlText: sqlText ?? Self.defaultSQL,
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

    public func createTopRowsQuery(for tableName: String) {
        createQuery(
            title: "\(tableName) Top 10",
            sqlText: """
            SELECT *
            FROM \(quoteIdentifier(tableName))
            LIMIT 10;
            """,
            activate: true,
            runImmediately: true,
            isSaved: false
        )
    }

    public func closeQuery(id: UUID) {
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

    private func run(queryID: UUID) {
        guard let queryIndex = index(for: queryID) else { return }

        let requestToken = (requestTokens[queryID] ?? 0) + 1
        requestTokens[queryID] = requestToken

        queries[queryIndex].isRunning = true
        queries[queryIndex].errorMessage = nil
        let sqlText = queries[queryIndex].sqlText

        Task {
            do {
                let result = try await databaseService.executeReadOnlyQuery(sql: sqlText)
                guard requestTokens[queryID] == requestToken,
                      let queryIndex = index(for: queryID)
                else {
                    return
                }
                queries[queryIndex].result = result
                queries[queryIndex].isRunning = false
            } catch {
                guard requestTokens[queryID] == requestToken,
                      let queryIndex = index(for: queryID)
                else {
                    return
                }
                queries[queryIndex].errorMessage = SQLiteUserError.from(error).message
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
        QueryDocument(title: nextUntitledName(), sqlText: Self.defaultSQL)
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

    private func storageKey(for databaseURL: URL) -> String {
        "SQLiteGraphStudio.saved-queries.\(databaseURL.path)"
    }

    private static let defaultSQL = """
    SELECT name, type
    FROM sqlite_master
    WHERE type IN ('table', 'view')
    ORDER BY name;
    """
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
