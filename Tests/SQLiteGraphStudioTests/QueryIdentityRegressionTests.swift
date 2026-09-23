import Foundation
import Testing
@testable import StudioCore

struct QueryIdentityRegressionTests {
    @Test func separateReadOnlySQLiteConnectionDisablesTrustedSchema() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-reader-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = DatabaseService()
        try await writer.open(url: url)
        await writer.close()

        let reader = DatabaseService()
        try await reader.open(url: url, readOnly: true)
        let trusted = try await reader.executeReadOnlyQuery(sql: "PRAGMA trusted_schema")
        let queryOnly = try await reader.executeReadOnlyQuery(sql: "PRAGMA query_only")
        #expect(trusted.rows.first?.values.first == .integer(0))
        #expect(queryOnly.rows.first?.values.first == .integer(1))
        await reader.close()
    }

    @Test func sqliteDuplicateAliasesKeepPositionalValues() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-\(UUID().uuidString).sqlite")
        let service = DatabaseService()
        try await service.open(url: url)
        let result = try await service.executeReadOnlyQuery(sql: "SELECT 1 AS id, 2 AS id, 3 AS id_2")
        #expect(result.rows.first?.values == [.integer(1), .integer(2), .integer(3)])
        #expect(Set(result.columns.map(\.id)).count == 3)
        await service.close()
    }
    @Test func duplicateColumnJSONPreservesNamesAndValuesForBothBackends() async throws {
        let result = QueryResult(
            columns: ["id", "id", "id_2", "id"].map { QueryResultColumn(name: $0, typeLabel: "INTEGER") },
            rows: [QueryResultRow(id: 0, values: [.integer(1), .integer(2), .integer(3), .null])],
            isTruncated: false, rowLimit: 500)
        let sqlite = SQLiteDatabaseBackend()
        let postgres = PostgresDatabaseBackend(configuration: .init(host: "unused", port: 5432, database: "unused", username: "unused", tlsMode: .disabled))
        for backend: any DatabaseBackend in [sqlite, postgres] {
            let json = try await backend.serializeQueryResult(result, format: .json)
            let rows = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            #expect(rows[0]["id"] as? Int == 1)
            #expect(rows[0]["id_3"] as? Int == 2)
            #expect(rows[0]["id_2"] as? Int == 3)
            #expect(rows[0]["id_4"] is NSNull)
        }
    }

}
