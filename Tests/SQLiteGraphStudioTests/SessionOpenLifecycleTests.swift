import Foundation
import GRDB
import Testing
@testable import StudioCore

@MainActor struct SessionOpenLifecycleTests {
    @Test func documentPanelUsesExtensionsAndAllowsDirectoryNavigation() throws {
        let filter = DatabaseDocumentOpenPanelDelegate(extensions: ["sqlite", "db"])
        #expect(filter.panel(NSNull(), shouldEnable: URL(fileURLWithPath: "/tmp/test.sqlite")))
        #expect(filter.panel(NSNull(), shouldEnable: URL(fileURLWithPath: "/tmp/test.DB")))
        #expect(!filter.panel(NSNull(), shouldEnable: URL(fileURLWithPath: "/tmp/test.txt")))
        #expect(filter.panel(NSNull(), shouldEnable: FileManager.default.temporaryDirectory))
    }
    @Test func staleImportTargetCannotWriteToDifferentDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.sqlite")
        let second = directory.appendingPathComponent("second.sqlite")
        for url in [first, second] {
            let fixture = try DatabaseQueue(path: url.path)
            try await fixture.write { db in try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY); INSERT INTO items VALUES(1)") }
        }
        let service = DatabaseService()
        try await service.open(url: first)
        let descriptor = try await service.fetchDescriptor(named: "items")
        try await service.open(url: second)
        await #expect(throws: CancellationError.self) {
            try await service.importRows(into: descriptor, text: "id\n99\n", format: .csv, expectedTarget: .sqlite(first))
        }
        let result = try await service.executeReadOnlyQuery(sql: "SELECT id FROM items ORDER BY id")
        #expect(result.rows.map(\.values) == [[.integer(1)]])
        await service.close()
    }

    @Test func closeDuringCatalogLoadCannotReopenSession() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-open-\(UUID().uuidString).sqlite")
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in
            for index in 0..<100 { try db.execute(sql: "CREATE TABLE t\(index)(id INTEGER PRIMARY KEY, value TEXT)") }
        }
        let session = AppSession(databaseService: DatabaseService())
        let opening = Task { await session.openDatabase(url: url) }
        await Task.yield()
        session.closeDatabase()
        await opening.value
        #expect(!session.hasOpenDatabase)
        #expect(session.databaseURL == nil)
    }
    @Test func closeThenImmediateOpenKeepsNewSession() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-reopen-\(UUID().uuidString).sqlite")
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in try db.execute(sql: "CREATE TABLE item(id INTEGER PRIMARY KEY)") }
        let session = AppSession(databaseService: DatabaseService())
        session.closeDatabase()
        await session.openDatabase(url: url)
        #expect(session.databaseURL == url)
        #expect(session.presentedError == nil)
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to verify PostgreSQL refresh metadata"))
    func postgresRefreshPreservesDocumentMetadata() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment).connection
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-refresh-\(UUID().uuidString).postgres")
        let document = PostgresConnectionDocument(host: config.host, port: config.port, database: config.database, username: config.username, tlsMode: config.tlsMode)
        try JSONEncoder().encode(document).write(to: url)
        let sidecar = SchemaSidecar(tables: ["public.items": .init(description: "Refresh keeps this")])
        try SchemaSidecarStore.save(sidecar, for: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: SchemaSidecarStore.sidecarURL(for: url)) }
        let session = AppSession(databaseService: DatabaseService())
        await session.openDocument(url: url)
        #expect(session.schemaSidecar == sidecar)
        session.refreshSchema()
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.databaseURL == url)
        #expect(session.schemaSidecar == sidecar)
        session.closeDatabase()
    }

}
