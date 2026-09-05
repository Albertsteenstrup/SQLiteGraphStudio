import Foundation
import Testing
@testable import StudioCore

struct PostgreSQLBrowsingFixtureTests {
    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled && ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_TESTS"] == "1", "Set SGS_POSTGRES_TESTS=1 and SGS_POSTGRES_FIXTURE_TESTS=1 with the owned browsing fixture"))
    func typedFiltersCountsAndCompositePages() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            let descriptor = try await backend.fetchDescriptor(named: "public.items")
            let exact = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: "id", value: "2", comparison: .equal)]), descriptor: descriptor)
            #expect(exact.rows.count == 1)
            let range = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: "amount", value: "10.1234567890", comparison: .between, upperValue: "12.1234567890")]), descriptor: descriptor)
            #expect(range.rows.count == 3)
            let nulls = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: "label", comparison: .isNull)], limit: 10), descriptor: descriptor)
            #expect(nulls.rows.count == 10)
            #expect(nulls.rows.allSatisfy { $0.values[2] == .null })
            let booleans = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: "active", value: "true", comparison: .equal)], limit: 5), descriptor: descriptor)
            #expect(booleans.rows.allSatisfy { $0.values[4] == .boolean(true) })
            var query = TableQueryState(sort: .init(columnName: "label", direction: .descending), limit: 73)
            var values: [[SQLiteValue]] = []
            for _ in 0..<20 {
                let page = try await backend.fetchChunk(query: query, descriptor: descriptor)
                if values.isEmpty { #expect(page.countState == .atLeast(73)) }
                values += page.rows.map(\.values)
                guard page.rows.count == 73, let last = page.rows.last else { break }
                query.offset = values.count
                query.after = .init(values: Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), last.values)))
            }
            let expected = try await backend.executeReadOnlyQuery(sql: "SELECT * FROM public.items ORDER BY label DESC NULLS LAST, tenant ASC, id ASC", rowLimit: 2000)
            #expect(values == expected.rows.map(\.values))
            #expect(values.count == 1205)
            query.offset = 0; query.after = nil; query.requestExactCount = true; query.limit = 2
            let counted = try await backend.fetchChunk(query: query, descriptor: descriptor)
            #expect(counted.countState == .exact(1205))
            let keyless = try await backend.fetchDescriptor(named: "public.keyless")
            #expect(keyless.paginationKeyColumns.isEmpty)
            #expect(keyless.pagingDescription.contains("no unique key"))
            let keylessRows = try await backend.fetchChunk(query: .init(limit: 10), descriptor: keyless)
            #expect(keylessRows.rows.count == 3)
            await #expect(throws: DatabaseUserError.self) { try await backend.insertDefaultRow(into: descriptor) }
            await #expect(throws: DatabaseUserError.self) { try await backend.executeReadOnlyQuery(sql: "WITH changed AS (DELETE FROM public.items RETURNING *) SELECT * FROM changed") }
            await backend.close()
        } catch { await backend.close(); throw error }
    }
}
