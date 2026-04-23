import Foundation
import Observation

@MainActor
@Observable
public final class QueryWorkspaceModel {
    public var sqlText = """
    SELECT name, type
    FROM sqlite_master
    WHERE type IN ('table', 'view')
    ORDER BY name;
    """
    public var result: QueryResult = .empty
    public var isRunning = false
    public var errorMessage: String?

    private let databaseService: DatabaseService

    public init(databaseService: DatabaseService) {
        self.databaseService = databaseService
    }

    public func reset() {
        result = .empty
        errorMessage = nil
    }

    public func run() {
        Task {
            isRunning = true
            errorMessage = nil
            defer { isRunning = false }

            do {
                result = try await databaseService.executeReadOnlyQuery(sql: sqlText)
            } catch {
                errorMessage = SQLiteUserError.from(error).message
            }
        }
    }
}
