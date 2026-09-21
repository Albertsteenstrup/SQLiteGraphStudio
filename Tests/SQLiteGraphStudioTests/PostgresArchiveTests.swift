import CryptoKit
import Foundation
import Testing
@testable import StudioCore

struct PostgresArchiveTests {
    @Test @MainActor func pickerAcceptsBackupsAndConnectionDocuments() {
        let filter = DatabaseDocumentOpenPanelDelegate(extensions: DatabaseDocument.otherExtensions)
        for name in ["fjordholm.dump", "backup.DUMP", "backup.backup", "live.postgres", "live.pgstudio"] {
            #expect(filter.panel(NSObject(), shouldEnable: URL(fileURLWithPath: "/tmp/" + name)))
        }
        #expect(!filter.panel(NSObject(), shouldEnable: URL(fileURLWithPath: "/tmp/image.png")))
        #expect(!DatabaseDocument.isArchive(URL(fileURLWithPath: "/tmp/live.postgres")))
    }

    @Test func archiveIdentityRoundTripsWithoutEphemeralConnection() throws {
        let url = URL(fileURLWithPath: "/tmp/catalog.dump")
        let target = DatabaseTarget.postgresDump(url)
        let data = try JSONEncoder().encode(target)
        #expect(try JSONDecoder().decode(DatabaseTarget.self, from: data) == target)
        #expect(target.fileURL == url)
        #expect(target.displayName == "catalog.dump")
        #expect(target.isPostgres)
        #expect(target.stableStorageKey != DatabaseTarget.postgresDump(URL(fileURLWithPath: "/tmp/another.dump")).stableStorageKey)
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
        #expect(!String(decoding: data, as: UTF8.self).contains("port"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_ARCHIVE_TEST_FILE to test a real dump in a disposable cluster"))
    @MainActor func selectedDumpOpensReadOnlyAndReopensWithMetadata() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-archive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Include spaces and punctuation to exercise argument handling.
        let selected = directory.appendingPathComponent("selected backup ' copy.dump")
        try FileManager.default.copyItem(at: source, to: selected)
        let originalHash = SHA256.hash(data: try Data(contentsOf: selected))
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let service = DatabaseService()
        let session = AppSession(databaseService: service, userDefaults: defaults)
        await session.openDocument(url: selected)
        let error = session.presentedError
        #expect(error == nil, "\(error?.message ?? "") \(error?.recoverySuggestion ?? "")")
        guard error == nil else { await service.close(); return }
        #expect(session.databaseURL == selected)
        #expect(session.databaseTarget == .postgresDump(selected))
        #expect(session.databaseCapabilities == .postgresReadOnly)
        #expect(session.recentDatabaseURLs.contains(selected))
        #expect(!session.tables.isEmpty)
        let tableCount = session.tables.count
        let graphEdges = session.graph.edges.count
        print("Archive verification: \(tableCount) catalog objects, \(graphEdges) relationships")
        let identity = session.databaseTarget?.stableStorageKey
        let result = try await service.executeReadOnlyQuery(sql: "SELECT current_user, current_setting('transaction_read_only'), (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)")
        #expect(result.rows.first?.values == [.text("studio_reader"), .text("on"), .boolean(false)])
        let table = try #require(session.tables.first)
        let descriptor = try await service.fetchDescriptor(named: table.name)
        let rows = try await service.executeReadOnlyQuery(sql: "SELECT count(*) FROM \(descriptor.qualifiedSQLIdentifier)")
        #expect(rows.rows.count == 1)
        await #expect(throws: (any Error).self) { try await service.executeReadOnlyQuery(sql: "CREATE TABLE should_fail(id int)") }
        let sidecar = SchemaSidecar(tables: [table.name: .init(description: "Backup metadata")])
        try SchemaSidecarStore.save(sidecar, for: selected)
        session.closeDatabase()
        await session.openDocument(url: selected)
        #expect(session.presentedError == nil)
        #expect(session.tables.count == tableCount)
        #expect(session.databaseTarget?.stableStorageKey == identity)
        #expect(session.schemaSidecar == sidecar)
        #expect(session.documentOpenProgress == nil)
        await service.close()
        #expect(await service.currentTarget == nil)
        #expect(SHA256.hash(data: try Data(contentsOf: selected)) == originalHash)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"] != nil,
                   "Requires local PostgreSQL tools"))
    func invalidArchiveFailsWithoutOpeningPartialDatabase() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dump")
        try Data("not a PostgreSQL dump".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = DatabaseService()
        await #expect(throws: DatabaseUserError.self) { try await service.open(dump: url) }
        #expect(await service.currentTarget == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"] != nil,
                   "Requires local PostgreSQL tools"))
    func cancellingRestoreCleansUpPrivateCluster() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_ARCHIVE_TEST_FILE"]))
        let service = DatabaseService()
        let opening = Task { try await service.open(dump: url) }
        try await Task.sleep(for: .milliseconds(250))
        await service.close()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await service.currentTarget == nil)
    }
}
