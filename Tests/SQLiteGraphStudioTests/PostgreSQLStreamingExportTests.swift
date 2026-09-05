import Foundation
import Testing
@testable import StudioCore

@Suite(.serialized, .enabled(if: PostgreSQLTestConfiguration.isEnabled && ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_TESTS"] == "1", "Requires explicitly opted-in owned items fixture"))
struct PostgreSQLStreamingExportTests {
    @Test func exportsAllMatchingRowsInOrderBeyondCurrentPage() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let descriptor = try await backend.fetchDescriptor(named: "public.items")
            let query = TableQueryState(columnFilters: [.init(columnName: "id", value: "602", comparison: .lessThanOrEqual)], sort: .init(columnName: "id", direction: .descending), offset: 100, limit: 50)
            let chunk = try await backend.fetchChunk(query: query, descriptor: descriptor)
            #expect(chunk.rows.count == 50)
            let destination = directory.appendingPathComponent("all.json")
            let count = try await backend.exportTableRows(query: query, descriptor: descriptor, to: destination, format: .json)
            #expect(count == 602)
            let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
            #expect(rows.count == 602)
            #expect(rows.first?["id"] as? Int == 602)
            #expect(rows.last?["id"] as? Int == 1)
            #expect(rows.contains { $0["label"] is NSNull })
            let unfiltered = directory.appendingPathComponent("unfiltered.csv")
            #expect(try await backend.exportTableRows(query: .init(offset: 1000, limit: 50), descriptor: descriptor, to: unfiltered, format: .csv) == 1205)
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test func cancellationRemovesPartialAndBackendRemainsReadOnly() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let descriptor = try await backend.fetchDescriptor(named: "public.items")
            let destination = directory.appendingPathComponent("cancelled.json")
            try "previous".write(to: destination, atomically: true, encoding: .utf8)
            let cancellation = ExportCancellation()
            do {
                _ = try await backend.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .json, cancellation: cancellation) { count in
                    if count == 128 { cancellation.cancel() }
                }
                Issue.record("Cancelled PostgreSQL export must throw")
            } catch is CancellationError { }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cancelled.json"])
            let setting = try await backend.executeReadOnlyQuery(sql: "SHOW transaction_read_only")
            #expect(setting.rows.first?.values.first?.displayText == "on")
            #expect(try await backend.fetchChunk(query: .init(limit: 1), descriptor: descriptor).rows.count == 1)
            await backend.close()
        } catch { await backend.close(); throw error }
    }
}
